#!/bin/bash

THIS_DIR=$(dirname "${BASH_SOURCE}")
source "${THIS_DIR}/shutils.sh"

CERT_AUTHORITY_DIR="${THIS_DIR}/certificate_authority"
DH_DIR="${THIS_DIR}/diffie_hellman"
TEMP_DIR="${THIS_DIR}/temp"

function configure_ip_forwarding() {
	LOG_doing "Enabling ip forwarding"
	local conf="/etc/sysctl.conf"
	backup_file "${conf}"
	as_root sed -i "/net.ipv4.ip_forward=/c\net.ipv4.ip_forward=1" "${conf}"
	as_root sysctl -p "${conf}"
}

function init_certificate_authority() {
	local dir="${1}"
	local name="${2}"
	local policy="${3}"
	make_dir "${dir}"
	make_dir "${dir}/certs"
	make_dir "${dir}/new_certs"
	make_dir "${dir}/crl"
	make_dir "${dir}/csr"
	make_dir "${dir}/private"
	set_mode 700 "${dir}/private"

	write_file "${dir}/index.txt" << \
END_TEXT
END_TEXT

	write_file "${dir}/serial" << \
END_TEXT
1000
END_TEXT
	write_file "${dir}/openssl.cnf" << \
END_TEXT
[ ca ]
# (man ca)
default_ca = CA_default

[ CA_default ]
# Directory and file locations.
dir               = ${dir}
certs             = \$dir/certs
new_certs_dir     = \$dir/new_certs
crl_dir           = \$dir/crl
database          = \$dir/index.txt
serial            = \$dir/serial
RANDFILE          = \$dir/private/.rand

# The root key and root certificate.
private_key       = \$dir/private/${name}-ca.key.pem
certificate       = \$dir/certs/${name}-ca.cert.pem

# For certificate revocation lists.
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/${name}-ca.crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30

# SHA-1 is deprecated, so use SHA-2 instead.
default_md        = sha256

name_opt          = ca_default
cert_opt          = ca_default
default_days      = 3650
preserve          = no
policy            = ${policy}

[ policy_strict ]
# The root CA should only sign intermediate certificates that match.
# See the POLICY FORMAT section of ca man page.
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ policy_loose ]
# Allow the intermediate CA to sign a more diverse range of certificates.
# See the POLICY FORMAT section of the ca man page.
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
# Options for the req tool (man req).
default_bits        = 4096
distinguished_name  = req_distinguished_name
string_mask         = utf8only

# SHA-1 is deprecated, so use SHA-2 instead.
default_md          = sha256

# Extension to add when the -x509 option is used.
x509_extensions     = v3_ca

[ req_distinguished_name ]
# See <https://en.wikipedia.org/wiki/Certificate_signing_request>.
countryName                     = US
stateOrProvinceName             = Freedom State
localityName                    = Freedom Locality
0.organizationName              = Freedom Organization
organizationalUnitName          = Freedom Unit
commonName                      = Freedom Name
emailAddress                    = you@all.free

# Optionally, specify some defaults.
countryName_default             = US
stateOrProvinceName_default     = Freedom State
localityName_default            = Freedom Locality
0.organizationName_default      = Freedom Organization
organizationalUnitName_default  = Freedom Unit
commonName_default              = Freedom Name
emailAddress_default            = you@all.free

[ v3_ca ]
# Extensions for a typical CA (man x509v3_config).
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_intermediate_ca ]
# Extensions for a typical intermediate CA (man x509v3_config).
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ usr_cert ]
# Extensions for client certificates (man x509v3_config).
basicConstraints = CA:FALSE
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, emailProtection

[ server_cert ]
# Extensions for server certificates (man x509v3_config).
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ crl_ext ]
# Extension for CRLs (man x509v3_config).
authorityKeyIdentifier=keyid:always

[ ocsp ]
# Extension for OCSP signing certificates (man ocsp).
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, OCSPSigning
END_TEXT

		write_file "${dir}/private/${name}-ca.key.pem.pass" << \
END_TEXT
$(openssl rand -base64 32)
END_TEXT
}

function configure_certificate_authority() {
	#FIXME: Assuming that CA was already created othewise
	if ! [[ -d "${CERT_AUTHORITY_DIR}" ]]; then
		make_dir "${CERT_AUTHORITY_DIR}"
		local ca_dir=$(realpath "${CERT_AUTHORITY_DIR}")

		LOG_doing "Creating root certificate authority"
		local root_ca="${ca_dir}/root"
		init_certificate_authority "${root_ca}" "root" "policy_strict"

		openssl genrsa \
			-aes256 \
			-passout "file:${root_ca}/private/root-ca.key.pem.pass" \
			-out "${root_ca}/private/root-ca.key.pem" \
			4096
		set_mode 400 "${root_ca}/private/root-ca.key.pem"

		openssl req \
			-config "${root_ca}/openssl.cnf" \
			-subj "/C=US/ST=State/L=Locality/O=Organization/OU=Unit/CN=Root/emailAddress=email@address.domain" \
			-key "${root_ca}/private/root-ca.key.pem" \
			-new -x509 -days 7300 -sha256 -extensions v3_ca \
			-passin "file:${root_ca}/private/root-ca.key.pem.pass" \
			-out "${root_ca}/certs/root-ca.cert.pem"

		LOG_doing "Creating intermediate certificate authority"
		local intermediate_ca="${ca_dir}/intermediate"
		init_certificate_authority "${intermediate_ca}" "intermediate" "policy_loose"

		openssl genrsa \
			-aes256 \
			-passout "file:${intermediate_ca}/private/intermediate-ca.key.pem.pass" \
			-out "${intermediate_ca}/private/intermediate-ca.key.pem" \
			4096
		set_mode 400 "${intermediate_ca}/private/intermediate-ca.key.pem"

		openssl req \
			-config "${intermediate_ca}/openssl.cnf" \
			-subj "/C=US/ST=State/L=Locality/O=Organization/OU=Unit/CN=Intermediate/emailAddress=email@address.domain" \
			-key "${intermediate_ca}/private/intermediate-ca.key.pem" \
			-new -sha256 \
			-passin "file:${intermediate_ca}/private/intermediate-ca.key.pem.pass" \
			-out "${intermediate_ca}/csr/intermediate-ca.csr.pem"

		LOG_doing "Creating intermediate certificate"
		openssl ca \
			-config "${root_ca}/openssl.cnf" \
			-batch \
			-extensions v3_intermediate_ca \
			-days 3650 -notext -md sha256 \
			-passin "file:${root_ca}/private/root-ca.key.pem.pass" \
			-in "${intermediate_ca}/csr/intermediate-ca.csr.pem" \
			-out "${intermediate_ca}/certs/intermediate-ca.cert.pem"

		LOG_doing "Creating certificate chain"
		write_file "${intermediate_ca}/certs/intermediate-ca-chain.cert.pem" << \
END_TEXT
$(cat "${intermediate_ca}/certs/intermediate-ca.cert.pem")
$(cat "${root_ca}/certs/root-ca.cert.pem")
END_TEXT

	fi
}

function configure_diffie_hellman() {
	if ! [[ -d "${DH_DIR}" ]]; then
		make_dir "${DH_DIR}"
	fi
	local dhparam="${DH_DIR}/dhparam.pem"
	if [[ ! -f ${dhparam} ]]; then
		LOG_doing "Generating Diffie-Hellman parameters"
		openssl dhparam \
			-out "${dhparam}" \
			2048
	fi
	local dhkey="${DH_DIR}/dhkey.pem"
	if [[ ! -f ${dhkey} ]]; then
		LOG_doing "Generating Diffie-Hellman private key"
		openssl genpkey \
			-paramfile "${dhparam}" \
			-out "${dhkey}"
	fi
	local dhpubkey="${DH_DIR}/dhpubkey.pem"
	if [[ ! -f ${dhpubkey} ]]; then
		LOG_doing "Generating Diffie-Hellman public key"
		openssl pkey \
			-in "${dhkey}" \
			-pubout \
			-out "${dhpubkey}"
	fi
}

function sign_csr() {
	local csr="${1}"
	local certificate="${2}"
	local name=$(basename "${csr}")
	local extension="server_cert" # Use "usr_cert" for user auth
	LOG_doing "Signing certificate signing request for \"${name}\""
	openssl ca \
		-config "${CERT_AUTHORITY_DIR}/intermediate/openssl.cnf" \
		-batch \
		-extensions "${extension}" \
		-days 375 -notext -md sha256 \
		-passin "file:${CERT_AUTHORITY_DIR}/intermediate/private/intermediate-ca.key.pem.pass" \
		-in "${csr}" \
		-out "${certificate}"
	chmod 444 "${certificate}"
}

function sign_csr_dh() {
	bail_out "Diffie Hellman certificate signing was not tested"
	local csr="${1}"
	local certificate="${2}"
	local name=$(basename "${csr}")
	local extension="server_cert" # Use "usr_cert" for user auth
	LOG_doing "Signing certificate signing request for \"${name}\" (Diffie Hellman)"
	openssl x509 \
		-req -in "${csr}" \
		-extensions "${extension}" \
		-CAkey "${CERT_AUTHORITY_DIR}/intermediate/private/intermediate-ca.key.pem" \
		-passin "file:${CERT_AUTHORITY_DIR}/intermediate/private/intermediate-ca.key.pem.pass" \
		-CA "${CERT_AUTHORITY_DIR}/intermediate/certs/intermediate-ca.cert.pem" \
		-force_pubkey "${DH_DIR}/dhpubkey.pem" \
		-out "${certificate}" \
		-CAcreateserial
}

function issue_certificate_with_name() {
	local name="${1}"
	local private_key="${CERT_AUTHORITY_DIR}/intermediate/private/${name}.key.pem"
	local certificate="${CERT_AUTHORITY_DIR}/intermediate/certs/${name}.cert.pem"
	if [[ ! -f ${private_key} ]]; then
		LOG_doing "Creating private key for \"${name}\""
		openssl genrsa \
			-out "${private_key}" \
			2048
		set_mode 400 "${private_key}"
	fi

	if [[ ! -f ${certificate} ]]; then
		local csr="${CERT_AUTHORITY_DIR}/intermediate/csr/${name}.csr.pem"
		LOG_doing "Creating certificate signing request for \"${name}\""
		openssl req \
			-config "${CERT_AUTHORITY_DIR}/intermediate/openssl.cnf" \
			-subj "/C=US/ST=State/L=Locality/O=Organization/OU=Unit/CN=${name}/emailAddress=email@address.domain" \
			-key "${private_key}" \
			-new -sha256 \
			-out "${csr}"
		sign_csr "${csr}" "${certificate}"
	fi
	LOG_doing "Verifying certificate for \"${name}\""
	openssl verify \
		-CAfile "${CERT_AUTHORITY_DIR}/intermediate/certs/intermediate-ca-chain.cert.pem" \
		"${certificate}" || bail_out "Certificate for \"${name}\" can't be verified"

	LOG_info "Certificate files:"
	LOG_info "\"${certificate}\" (certificate)"
	LOG_info "\"${private_key}\" (private key)"
	LOG_info "\"${CERT_AUTHORITY_DIR}/intermediate/certs/intermediate-ca-chain.cert.pem\" (issuing authority certificate)"
}

function configure_openvpn() {
	local hostname="${1}"
	! [[ -z ${hostname}  ]] || bail_out "Hostname is required for OpenVPN configuration"
	local ca_dir=$(realpath "${CERT_AUTHORITY_DIR}")
	local dh_dir=$(realpath "${DH_DIR}")
	local openvpn_temp_dir=$(real_dir "${TEMP_DIR}/openvpn")
	local openvpn_dir="/etc/openvpn"

	LOG_doing "Collecting files"
	rm -rf "${openvpn_temp_dir}"
	make_dir "${openvpn_temp_dir}"
	make_dir "${openvpn_temp_dir}/keys"
	cp "${ca_dir}/intermediate/certs/intermediate-ca-chain.cert.pem" "${openvpn_temp_dir}/keys/ca.cert.pem"
	cp "${ca_dir}/intermediate/certs/${hostname}.cert.pem" "${openvpn_temp_dir}/keys/${hostname}.cert.pem"
	cp "${ca_dir}/intermediate/private/${hostname}.key.pem" "${openvpn_temp_dir}/keys/${hostname}.key.pem"
	cp "${dh_dir}/dhparam.pem" "${openvpn_temp_dir}/keys/dhparam.pem"

	LOG_doing "Writing OpenVPN config"
	write_file "${openvpn_temp_dir}/server.conf" << \
END_TEXT
# Which local IP address should OpenVPN listen on? (optional)
;local a.b.c.d

# Which TCP/UDP port should OpenVPN listen on?
port 1194

# TCP or UDP server?
;proto tcp
proto udp

# "dev tun" will create a routed IP tunnel, "dev tap" will create an ethernet tunnel.
;dev tap
dev tun

# SSL/TLS root certificate (ca), certificate (cert), and private key (key). Each client
# and the server must have their own cert and key file.  The server and all clients will
# use the same ca file.
ca ${openvpn_dir}/keys/ca.cert.pem
cert ${openvpn_dir}/keys/${hostname}.cert.pem
key ${openvpn_dir}/keys/${hostname}.key.pem

# Diffie hellman parameters.
dh ${openvpn_dir}/keys/dhparam.pem

# Algorithms
cipher AES-256-CBC
auth SHA512

# Configure server mode and supply a VPN subnet for OpenVPN to draw client addresses from.
# The server will take 10.8.0.1 for itself, the rest will be made available to clients.
# Each client will be able to reach the server on 10.8.0.1.
server 10.8.0.0 255.255.255.0

# Instruct any connecting client to route all of its traffic across the VPN, ignoring any
# settings it might have to the contrary from its local DHCP server.
push "redirect-gateway def1 bypass-dhcp"

# Force the client to use Google's multicast DNS servers.
# Alternatives:
# Level 3 DNS servers - 4.2.2.4, 4.2.2.2
# OpenDNS - 208.67.222.222, 208.67.220.220
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"

# Ping every 10 seconds, assume that remote peer is down if no ping received during
# a 120 second time period.
keepalive 10 120

# Enable compression on the VPN link. 
comp-lzo

# The persist options will try to avoid  accessing certain resources on restart that
# may no longer be accessible because of the privilege downgrade. 
persist-key
persist-tun

# Output a short status file showing current connections, truncated and rewritten every
# minute.
status openvpn-status.log

# By default, log messages will go to the syslog. "log" will truncate the log file on
# OpenVPN startup, while "log-append" will append to it.  Use one or the other, not both.
;log         openvpn.log
log-append  openvpn.log

# Set the appropriate level of log file verbosity (0-9). Default is 3.
verb 9
END_TEXT

	LOG_doing "Installing OpenVPN config"
	sudo cp -R ${openvpn_temp_dir}/* "${openvpn_dir}"
}

install_package openssl
install_package openvpn

configure_ip_forwarding
configure_certificate_authority
configure_diffie_hellman
issue_certificate_with_name "vpn.causaldomain.com"
configure_openvpn "vpn.causaldomain.com"
