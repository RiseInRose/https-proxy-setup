#!/bin/bash

REGION="US"
HOSTNAME="proxy-us.causaldomain.com"
HTTPD_PORTS=(443 80)
PROXY_PORTS=(465 995)
IFACE="eth0"
DEBUG=false

THIS_DIR=$(dirname "${BASH_SOURCE}")
CERT_PATH="${THIS_DIR}/${HOSTNAME}.crt"
CERT_CHAIN_PATH="${THIS_DIR}/${HOSTNAME}.chain.crt"
CERT_KEY_PATH="${THIS_DIR}/${HOSTNAME}.key"
IP=$(ip addr list ${IFACE} | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)
# See https://wiki.mozilla.org/Security/Server_Side_TLS
CIPHERS=(
	ECDHE-RSA-AES128-GCM-SHA256
	ECDHE-ECDSA-AES128-GCM-SHA256
	ECDHE-RSA-AES256-GCM-SHA384
	ECDHE-ECDSA-AES256-GCM-SHA384
	DHE-RSA-AES128-GCM-SHA256
	DHE-DSS-AES128-GCM-SHA256
	kEDH+AESGCM
	ECDHE-RSA-AES128-SHA256
	ECDHE-ECDSA-AES128-SHA256
	ECDHE-RSA-AES128-SHA
	ECDHE-ECDSA-AES128-SHA
	ECDHE-RSA-AES256-SHA384
	ECDHE-ECDSA-AES256-SHA384
	ECDHE-RSA-AES256-SHA
	ECDHE-ECDSA-AES256-SHA
	DHE-RSA-AES128-SHA256
	DHE-RSA-AES128-SHA
	DHE-DSS-AES128-SHA256
	DHE-RSA-AES256-SHA256
	DHE-DSS-AES256-SHA
	DHE-RSA-AES256-SHA
	!aNULL !eNULL !EXPORT
	!DES !RC4 !3DES !MD5 !PSK)
CONF_CERT_PATH="/etc/ssl/certs/${HOSTNAME}.crt"
CONF_CERT_CHAIN_PATH="/etc/ssl/certs/${HOSTNAME}.chain.crt"
CONF_CERT_FULL_PATH="/etc/ssl/certs/${HOSTNAME}.full.crt"
CONF_CERT_KEY_PATH="/etc/ssl/private/${HOSTNAME}.key"
CONF_DHPARAMS_PATH="/etc/ssl/certs/${HOSTNAME}.dhparams.pem"
CONF_PASSWD_PATH="/etc/passwd.proxy"

function if_debug() {
	if $DEBUG; then echo "${1}"; fi
}

function if_debug_else() {
	if $DEBUG; then echo "${1}"; else echo "${2}"; fi
}

function join() {
	local IFS="${1}"; shift; echo "$*"
}

function LOG_msg() {
	echo "> ${1}"
}

function LOG_doing() {
	LOG_msg "${1}..."
}

function yum_install() {
	local name="${1}"
	LOG_doing "Installing ${name}"
	sudo yum -y install "${name}" || exit 1
}

function backup_file() {
	local file="${1}"
	local dir=$(dirname "${file}")
	local name=$(basename "${file}")
	local bak=$(sudo mktemp -p "${dir}" "${name}.bak.XXXX")
	sudo cp "${file}" "${bak}" || exit 1
}

function sudo_write() {
	local file="${1}"
	sudo tee "${file}" > /dev/null
}

function install_packages() {
	yum_install git
	yum_install net-tools
	yum_install firewalld
	yum_install openssl
	yum_install httpd
	yum_install mod_ssl
	yum_install squid
}

function configure_network() {
	LOG_doing "Starting firewall service"
	sudo systemctl start firewalld.service || exit 1
	LOG_doing "Adding ${IFACE} to public zone"
	sudo firewall-cmd --permanent --zone=public --add-interface=${IFACE} || exit 1
	for port in ${HTTPD_PORTS[@]} ${PROXY_PORTS[@]}; do
		LOG_doing "Adding port ${port} to public zone"
		sudo firewall-cmd --permanent --zone=public --add-port=${port}/tcp || exit 1
	done
	LOG_doing "Reloading firewall settings"
	sudo firewall-cmd --reload || exit 1
}

function configure_tls() {
	LOG_doing "Writing certificate files"
	for path in "${CONF_CERT_PATH}" "${CONF_CERT_CHAIN_PATH}" "${CONF_CERT_FULL_PATH}"; do
		local dir=$(dirname "${path}")
		sudo mkdir -p "${dir}" || exit 1
	done
	for path in "${CONF_CERT_KEY_PATH}"; do
		local dir=$(dirname "${path}")
		sudo mkdir -p "${dir}" || exit 1
		sudo chmod 700 "${dir}" || exit 1
	done
	sudo cp "${CERT_PATH}" "${CONF_CERT_PATH}" || exit 1
	sudo cp "${CERT_CHAIN_PATH}" "${CONF_CERT_CHAIN_PATH}" || exit 1
	sudo cp "${CERT_KEY_PATH}" "${CONF_CERT_KEY_PATH}" || exit 1
	sudo chmod 600 "${CONF_CERT_KEY_PATH}" || exit 1
	cat "${CERT_PATH}" "${CERT_CHAIN_PATH}" | sudo tee "${CONF_CERT_FULL_PATH}" > /dev/null || exit 1
	LOG_doing "Generating DH parameters"
	sudo openssl dhparam -out "${CONF_DHPARAMS_PATH}" 2048
}

function configure_users() {
	LOG_doing "Creating nobody user"
	local FLAGS="-i"
	if [[ ! -f ${CONF_PASSWD_PATH} ]]; then
		FLAGS="${FLAGS}c"
	fi
	openssl rand -base64 32 | sudo htpasswd "${FLAGS}" "${CONF_PASSWD_PATH}" nobody
}

function configure_httpd() {
	LOG_doing "Creating httpd logs folder"
	local LOGS="/var/log/httpd"
	sudo mkdir -p "${LOGS}" || exit 1
	sudo chmod 700 "${LOGS}" || exit 1

	LOG_doing "Writing httpd configuration"
	local CONF="/etc/httpd/conf/httpd.conf"
	backup_file "${CONF}"
	sudo_write "${CONF}" << \
END_TEXT
ServerRoot "/etc/httpd"
Include conf.modules.d/*.conf
User apache
Group apache
$(printf "Listen %s https\n" "${HTTPD_PORTS[@]}")
SSLEngine on
SSLCertificateFile ${CONF_CERT_PATH}
SSLCertificateChainFile ${CERT_CHAIN_PATH}
SSLCertificateKeyFile ${CONF_CERT_KEY_PATH}
SSLCipherSuite $(join ":" "${CIPHERS[@]}")
SSLProtocol All -SSLv2 -SSLv3
SSLHonorCipherOrder on
ServerName ${HOSTNAME}:${HTTPD_PORTS[0]}
ServerAdmin admin@${HOSTNAME}
DocumentRoot "/var/www/html"
ScriptAlias "/report.cgi" "/var/www/cgi-bin/report.cgi"
<Directory />
    AllowOverride none
	Options None
    Require all denied
</Directory>
<Directory "/var/www/html">
    AllowOverride None
	Options None
    Require all granted
</Directory>
<Location "/report.cgi">
	AuthType Basic
	AuthName "Report access is limited"
	AuthBasicProvider file
	AuthUserFile "${CONF_PASSWD_PATH}"
	<RequireAll>
		Require valid-user
		Require not user nobody
	</RequireAll>
</Location>
<Files ".ht*">
    Require all denied
</Files>
<IfModule dir_module>
    DirectoryIndex index.html
</IfModule>
<IfModule mime_module>
    TypesConfig /etc/mime.types
    AddType application/x-ns-proxy-autoconfig .pac
</IfModule>
AddDefaultCharset UTF-8
LogLevel warn
ErrorLog "|/usr/sbin/rotatelogs -n 7 -L ${LOGS}/error_log ${LOGS}/error_log.old 86400 100M"
LogFormat "$(if_debug "%h ")%t \"%r\" %>s %b $(if_debug "\\\"%{User-Agent}i\\\"")" combined
CustomLog "|/usr/sbin/rotatelogs -n 7 -L ${LOGS}/access_log ${LOGS}/access_log.old 86400 100M" combined
END_TEXT

	LOG_doing "Generating report.cgi"
	local REPORT_CGI="/var/www/cgi-bin/report.cgi"
	sudo_write "${REPORT_CGI}" << \
END_TEXT
#!/bin/bash
echo "Content-type: text/plain"
echo ""
curl -s "https://${HOSTNAME}:${PROXY_PORTS[0]}/squid-internal-mgr/info"
END_TEXT
	sudo chmod a+x "${REPORT_CGI}"

	LOG_doing "Generating proxy.pac"
	sudo_write "/var/www/html/proxy.pac" << \
END_TEXT
function FindProxyForURL(url, host) {
return "$(printf "HTTPS ${HOSTNAME}:%s;" "${PROXY_PORTS[@]}")"
}
END_TEXT

	LOG_doing "Generating index.html"
	sudo_write "/var/www/html/index.html" << \
END_TEXT
<!DOCTYPE html>
<html>
<body>
<p>This HTTPS proxy is located in ${REGION} and listens on following TCP ports:</p>
<ul>$(printf "<li>%s</li>" "${PROXY_PORTS[@]}")</ul>
<p>Configuration URLs:</p>
<ul>$(printf "<li>https://${HOSTNAME}:%s/proxy.pac</li>" "${HTTPD_PORTS[@]}")</ul>
<p>Configuration script (PAC file):</p>
<code><pre>$(cat /var/www/html/proxy.pac)</pre></code>
<p>Realtime proxy <a href="/report.cgi">report</a>.</p>
<p>Proxy access log is <b>$(if_debug_else "enabled" "disabled")</b>.</p>
<p>Access is granted on per-request basis. Ping me to be granted proxy access.</p>
</body>
</html>
END_TEXT

	LOG_doing "Restarting httpd"
	sudo service httpd restart || exit 1
}

function configure_squid() {
	LOG_doing "Creating squid logs folder"
	local LOGS="/var/log/squid"
	sudo mkdir -p "${LOGS}" || exit 1
	sudo chmod 700 "${LOGS}" || exit 1

	LOG_doing "Writing squid configuration"
	local CONF="/etc/squid/squid.conf"
	backup_file "${CONF}"
	sudo_write "${CONF}" << \
END_TEXT
auth_param basic program /usr/lib64/squid/basic_ncsa_auth ${CONF_PASSWD_PATH}
auth_param basic children 5
auth_param basic realm Proxy access is limited
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on
acl PORTS port 22 $(join " " "${HTTPD_PORTS[@]}")
acl NOBODY proxy_auth nobody
acl AUTH proxy_auth REQUIRED
http_access allow localhost manager
http_access deny manager
http_access allow to_localhost PORTS
http_access deny to_localhost
http_access deny NOBODY
http_access allow AUTH
http_access deny all
$(printf "\
https_port %s \\
	cert=${CONF_CERT_FULL_PATH} \\
	key=${CONF_CERT_KEY_PATH} \\
	dhparams=${CONF_DHPARAMS_PATH} \\
	options=NO_SSLv2:NO_SSLv3:CIPHER_SERVER_PREFERENCE \\
	cipher=$(join ":" "${CIPHERS[@]}")\n\
" "${PROXY_PORTS[@]}")
coredump_dir /var/spool/squid
via off
forwarded_for off
follow_x_forwarded_for deny all
request_header_access X-Forwarded-For deny all
request_header_access CACHE-CONTROL deny all
cache_log ${LOGS}/cache_log
access_log $(if_debug_else "stdio:${LOGS}/access_log" "none")
logfile_rotate 2
debug_options ALL,1
END_TEXT

	LOG_doing "Restarting squid"
	sudo service squid restart || exit 1
}

install_packages
configure_network
configure_tls
configure_users
configure_httpd
configure_squid

LOG_msg "Done!"
echo ""
echo "To get squid report:"
printf "curl -s https://${HOSTNAME}:%s/squid-internal-mgr/info\n" "${PROXY_PORTS[@]}"
echo ""
echo "To add a new user:"
echo "sudo htpasswd ${CONF_PASSWD_PATH} <NAME>"
echo ""
echo "Configuration URLs:"
printf "https://${HOSTNAME}:%s/proxy.pac\n" "${HTTPD_PORTS[@]}"
