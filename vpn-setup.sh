#!/bin/bash

THIS_DIR=$(dirname "${BASH_SOURCE}")
source "${THIS_DIR}/shutils.sh"

CERT_AUTHORITY_DIR="${THIS_DIR}/certificate_authority"

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
		ca_dir=$(realpath "${CERT_AUTHORITY_DIR}")

		LOG_doing "Creating root certificate authority"
		root_ca="${ca_dir}/root"
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
		intermediate_ca="${ca_dir}/intermediate"
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

install_package openvpn

configure_ip_forwarding
configure_certificate_authority
