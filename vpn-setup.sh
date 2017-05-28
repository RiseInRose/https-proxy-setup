#!/bin/bash

THIS_DIR=$(dirname "${BASH_SOURCE}")
source "${THIS_DIR}/shutils.sh"

CERT_AUTHORITY_DIR="${THIS_DIR}/certificate_authority"

function configure_ip_forwarding() {
	LOG_doing "Enabling ip forwarding"
	conf="/etc/sysctl.conf"
	backup_file "${conf}"
	as_root sed -i "/net.ipv4.ip_forward=/c\net.ipv4.ip_forward=1" "${conf}"
	as_root sysctl -p "${conf}"
}

function configure_certificate_authority() {
	LOG_doing "Creating certificate authority"
	if ! [[ -d "${CERT_AUTHORITY_DIR}" ]]; then
		mkdir -p "${CERT_AUTHORITY_DIR}" || bail_out "Failed to create directory \"${CERT_AUTHORITY_DIR}\""
		chmod 700 "${CERT_AUTHORITY_DIR}" || bail_out "Failed to chmod directory \"${CERT_AUTHORITY_DIR}\""
	fi
}

install_package openvpn

configure_ip_forwarding
configure_certificate_authority
