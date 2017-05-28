function LOG_msg() {
	echo -e "> ${1}"
}

function LOG_doing() {
	local GREEN="\033[0;32m"
	local NC="\033[0m"
	LOG_msg "${GREEN}${1}...${NC}"
}

function LOG_err() {
	local RED="\033[0;31m"
	local NC="\033[0m"
	LOG_msg "${RED}Error: ${1}${NC}"
}

function bail_out() {
	LOG_err "${1}"
	exit -1
}

function suppress_output() {
	$@ >/dev/null 2>/dev/null
}

function as_root() {
	sudo $@
}

function backup_file() {
	local backups="$(pwd)/backups"
	local file="${1}"
	local dir=$(dirname "${file}")
	local name=$(basename "${file}")
	local bakdir="${backups}/${dir}"
	mkdir -p "${bakdir}"
	chmod 700 "${bakdir}"
	local bak=$(mktemp -p "${bakdir}" "${name}.bak.XXXX")
	cp "${file}" "${bak}" || bail_out "Failed to backup \"${file}\" to \"${bak}\""
}

function write_file() {
	local file="${1}"
	tee "${file}" > /dev/null
}

function make_dir() {
	dir="${1}"
	mkdir -p "${dir}" || bail_out "Failed to create directory \"${dir}\""
}

function set_mode() {
	mode="${1}"
	file="${2}"
	chmod "${mode}" "${file}" || bail_out "Failed to chmod ${mode} \"${file}\""
}

function install_package_apt_get() {
	local name="${1}"             
	as_root apt-get --assume-yes install "${name}"
}

function install_package() {
	local name="${1}"             
	LOG_doing "Installing ${name}"
	if suppress_output which apt-get; then
		install_package_apt_get "${name}"
		return $?
	fi
	LOG_err "Failed to install ${name}"
	return -1
}
