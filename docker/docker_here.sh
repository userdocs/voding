#!/bin/bash
_dh() {
	set -eo pipefail
	# Isolate error checking to avoid unexpected exits from `set -e`
	trap '[[ $? -eq 0 ]] || printf "\\n%b\\n" "${unicode_red_circle} ${color_red}ERROR:${color_end} An unexpected error occurred. Exiting." >&2' EXIT
	# Helper: robust docker exec attach with fallback and quick-exit diagnostics
	attach_shell() {
		local user="$1"
		shift
		local workdir="$1"
		shift
		local prefer_bash="$1"
		shift
		local shell_cmd
		if [[ ${prefer_bash} == true ]] && docker exec "${container_name}" bash -lc 'command -v bash >/dev/null 2>&1'; then
			shell_cmd="bash"
		elif docker exec "${container_name}" sh -lc 'command -v bash >/dev/null 2>&1' >/dev/null 2>&1; then
			shell_cmd="bash"
		else
			shell_cmd="sh"
		fi
		# Build exec options and only set -w if the directory exists in the container
		local exec_opts=(-it)
		if [[ -n ${user} ]]; then
			exec_opts+=(-u "${user}")
		fi
		local use_workdir=false
		if [[ -n ${workdir} ]] && docker exec "${container_name}" sh -lc "test -d '${workdir}'" >/dev/null 2>&1; then
			use_workdir=true
		fi
		if [[ ${use_workdir} == true ]]; then
			docker exec "${exec_opts[@]}" -w "${workdir}" "${container_name}" "${shell_cmd}"
		else
			docker exec "${exec_opts[@]}" "${container_name}" "${shell_cmd}"
		fi
		return $?
	}
	# Optional: respect NO_COLOR and non-interactive shells
	local enable_color=true
	if [[ -n ${NO_COLOR:-} || ! -t 1 ]]; then
		enable_color=false
	fi
	local color_red="\e[31m"
	local color_green="\e[32m"
	local color_yellow="\e[33m"
	local color_blue="\e[34m"
	local color_cyan="\e[36m"
	local color_magenta="\e[35m"
	local color_gray="\e[37m"
	local color_end="\e[0m"
	local text_bold="\e[1m"

	# Use 4-digit \u escape (\U expects 8 digits). Disable coloring when requested
	local unicode_red_circle="\e[31m\u2B24\e[0m"
	local unicode_green_circle="\e[32m\u2B24\e[0m"
	local unicode_yellow_circle="\e[33m\u2B24\e[0m"
	local unicode_blue_circle="\e[34m\u2B24\e[0m"

	if [[ ${enable_color} == false ]]; then
		color_red=""
		color_green=""
		color_yellow=""
		color_blue=""
		color_cyan=""
		color_magenta=""
		color_gray=""
		color_end=""
		text_bold=""
		unicode_red_circle="\u2B24"
		unicode_green_circle="\u2B24"
		unicode_yellow_circle="\u2B24"
		unicode_blue_circle="\u2B24"
	fi

	local volume_path
	local docker_platform
	local image_type="alpine"  # default to alpine
	local image_version="edge" # default version for alpine
	local use_sudo=false
	local use_limited=false
	local force_new=false
	local auto_remove=false
	local quiet=false
	local delete_all=false
	local target_user="${USER:-gh}"
	local additional_packages=""

	local host_uid="${SUDO_UID:-$(id -u)}"
	local host_gid="${SUDO_GID:-$(id -g)}"
	if [[ ${host_uid} -eq 0 ]]; then host_uid=1000; fi
	if [[ ${host_gid} -eq 0 ]]; then host_gid=1000; fi

	# Default values
	# Robust platform detection without dpkg (works on most Linux hosts)
	case "$(uname -m)" in
	x86_64 | amd64)
		docker_platform="linux/amd64"
		;;
	aarch64 | arm64)
		docker_platform="linux/arm64"
		;;
	armv7l)
		docker_platform="linux/arm/v7"
		;;
	armv6l)
		docker_platform="linux/arm/v6"
		;;
	ppc64le)
		docker_platform="linux/ppc64le"
		;;
	s390x)
		docker_platform="linux/s390x"
		;;
	*)
		docker_platform="linux/amd64" # sensible default
		;;
	esac
	volume_path="$(pwd)"

	# Parse arguments with getopts
	local OPTIND=1
	# (Debug of raw arguments removed to honor -q early)
	while getopts "aU:udDslP:p:i:v:hnrq" opt; do
		if [[ ${quiet} == false && ${opt} != "h" ]]; then
			printf '\n%b\n' "${unicode_yellow_circle} ${color_yellow}DEBUG:${color_end} Processing option: ${color_magenta}$opt${color_end}" >&2
		fi
		case ${opt} in
		a)
			image_type="alpine"
			image_version="edge"
			;;
		u)
			image_type="ubuntu"
			image_version="latest"
			;;
		d)
			image_type="debian"
			image_version="latest"
			;;
		D)
			delete_all=true
			;;
		U)
			target_user="${OPTARG}"
			;;
		P)
			additional_packages="${OPTARG}"
			;;
		s)
			use_sudo=true
			;;
		l)
			use_limited=true
			;;
		p)
			docker_platform="${OPTARG}" # NOSONAR
			;;
		i)
			if [[ ${OPTARG} =~ ^(alpine|ubuntu|debian):(.+)$ ]]; then
				image_type="${BASH_REMATCH[1]}"
				image_version="${BASH_REMATCH[2]}"
			else
				printf '\n%b\n' "${unicode_red_circle} Error: Invalid image format '${OPTARG}'. Use format: distro:version" >&2
				printf '\n%b\n\n' "${unicode_yellow_circle} Examples: alpine:latest, ubuntu:22.04, debian:bullseye" >&2
				return 1
			fi
			;;
		v)
			if [[ -n ${OPTARG} ]]; then
				local target_dir # NOSONAR
				if [[ ${OPTARG} == /* ]]; then
					target_dir="${OPTARG}"
				elif [[ ${OPTARG} == ~* ]]; then
					# Expand leading ~ manually since it's inside quotes
					target_dir="${OPTARG/#\~/${HOME}}"
				else
					target_dir="$(pwd)/${OPTARG}"
				fi
				mkdir -p "${target_dir}" || {
					printf '%b\n' "${unicode_red_circle} Error: Failed to create directory '${target_dir}'" >&2
					return 1
				}
				volume_path="${target_dir}"
			else
				printf '%b\n' "Error: -v requires a directory path" >&2
				return 1
			fi
			;;
		n)
			force_new=true
			;;
		r)
			auto_remove=true
			;;
		q)
			quiet=true
			;;
		h)
			printf '\n%b\n' "Usage: _dh [OPTIONS]"
			printf '\n%b\n' "Options:"
			printf '%b\n' "  -a          Use Alpine Linux (default: edge)"
			printf '%b\n' "  -u          Use Ubuntu (default: latest)"
			printf '%b\n' "  -d          Use Debian (default: latest)"
			printf '%b\n' "  -s          Run with sudo privileges"
			printf '%b\n' "  -l          Run in limited mode (no sudo)"
			printf '%b\n' "  -p PLATFORM Set docker platform (default: auto-detect)"
			printf '%b\n' "  -U USER     Specify username in container (default: gh)"
			printf '%b\n' '  -P PKGS     Specify extra packages to install (e.g. "curl wget nano")'
			printf '%b\n' "  -i IMAGE    Specify image:version (e.g., alpine:3.18)"
			printf '%b\n' "  -v PATH     Create (if needed) and use PATH as volume (absolute, relative, or ~)"
			printf '%b\n' "  -n          Force create new container (don't reuse existing)"
			printf '%b\n' "  -r          Auto-remove container on exit (--rm)"
			printf '%b\n' "  -q          Quiet mode (suppress debug messages)"
			printf '%b\n\n' "  -D          Delete existing container and its image before starting"
			printf '%b\n\n' "  -h          Show this help message"
			return 0
			;;
		\?)
			printf '%b\n' "Error: Invalid option -${OPTARG}. Use -h for help." >&2
			return 1
			;;
		:)
			printf '%b\n' "Error: Option -${OPTARG} requires an argument." >&2
			return 1
			;;
		esac
	done

	# Shift past the options
	shift $((OPTIND - 1))

	# Security: Validate username to prevent command injection.
	# Usernames typically start with a letter or underscore, followed by letters, digits, hyphens, or underscores.
	if [[ ! ${target_user} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
		printf '%b\n' "${unicode_red_circle} ${color_red}ERROR:${color_end} Invalid username specified: '${target_user}'" >&2
		printf '%b\n' "Usernames must match the regex: ^[a-z_][a-z0-9_-]{0,31}$" >&2
		return 1
	fi

	# Security: Validate additional packages to prevent command injection
	if [[ -n ${additional_packages} ]]; then
		# Create an array from the space-separated string
		read -r -a pkg_array <<<"${additional_packages}"
		for pkg in "${pkg_array[@]}"; do
			if [[ ! ${pkg} =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]]; then
				printf '%b\n' "${unicode_red_circle} ${color_red}ERROR:${color_end} Invalid package name specified: '${pkg}'" >&2
				return 1
			fi
		done
	fi

	# Debug: Show final values
	if [[ ${quiet} == false ]]; then
		printf '\n%b\n\n' "${unicode_yellow_circle} ${color_yellow}DEBUG:${color_end} Final values - ${color_blue}image_type=${color_green}\"${image_type}\"${color_end}  ${color_blue}image_version=${color_green}\"${image_version}\"${color_end}  ${color_blue}use_sudo=${color_green}\"${use_sudo}\"${color_end}  ${color_blue}additional_packages=${color_green}\"${additional_packages}\"${color_end}" >&2
	fi

	# Validate configuration
	if [[ ${use_sudo} == true && ${use_limited} == true ]]; then
		printf '%b\n\n' "${unicode_red_circle} ${color_red}ERROR:${color_end} ${color_magenta}-s${color_end} (sudo) and ${color_magenta}-l${color_end} (limited) options cannot be used together${color_end}" >&2
		return 1
	fi

	if [[ ${target_user} != "gh" && ${use_sudo} == false && ${use_limited} == false ]]; then
		printf '%b\n\n' "${unicode_yellow_circle} ${color_yellow}WARNING:${color_end} Custom user (-U ${target_user}) specified but no user mode (-s or -l) was enabled. Container will run as root." >&2
	fi

	# Ensure docker is available (after parsing so -h can exit early)
	if ! command -v docker >/dev/null 2>&1; then
		printf '%b\n' "${unicode_red_circle} ${color_red}ERROR:${color_end} Docker is not installed or not in PATH" >&2
		return 127
	fi

	# Ensure volume path exists and is accessible
	if [[ ! -d ${volume_path} ]]; then
		printf '%b\n' "${unicode_red_circle} Error: Volume path '${volume_path}' does not exist" >&2
		return 1
	fi

	# Ensure the chosen volume path is writable, otherwise warn.
	if [[ ! -w ${volume_path} ]]; then
		local current_user
		current_user="$(id -un 2>/dev/null || echo 'unknown')"
		printf '%b\n\n' "${unicode_yellow_circle} ${color_yellow}WARNING:${color_end} Volume path '${volume_path}' is not writable by user '${current_user}'. Container operations may fail."
	fi

	# Display container info
	printf '%b\n\n' "${unicode_blue_circle} ${text_bold}${color_gray}Starting ${color_blue}${image_type}${color_end}:${color_green}${image_version}${color_end} container...${color_end}"
	if [[ ${use_sudo} == false && ${use_limited} == false ]]; then
		printf '%b\n' "${unicode_green_circle} Volume:   ${color_magenta}${volume_path}${color_end} -> ${color_cyan}/root${color_end}"
	else
		printf '%b\n' "${unicode_green_circle} Volume:   ${color_magenta}${volume_path}${color_end} -> ${color_cyan}/home/${target_user}${color_end}"
	fi

	printf '%b\n' "${unicode_green_circle} Platform: ${color_magenta}${docker_platform}${color_end}"
	[[ ${use_sudo} == true ]] && printf '%b\n' "${unicode_green_circle} Mode:     ${color_magenta}sudo${color_end}"
	[[ ${use_limited} == true ]] && printf '%b\n' "${unicode_green_circle} Mode:     ${color_magenta}limited${color_end} (no sudo)"
	[[ ${use_sudo} == false && ${use_limited} == false ]] && printf '%b\n' "${unicode_green_circle} Mode:     ${color_magenta}root${color_end}"
	[[ -n ${additional_packages} ]] && printf '%b\n' "${unicode_green_circle} Packages: ${color_magenta}${additional_packages}${color_end}"
	printf '\n'

	# Generate container name based on distro and current directory
	local container_name
	container_name="${image_type}_$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_.-')"

	# If requested, delete existing container and its image before proceeding
	if [[ ${delete_all} == true ]]; then
		printf '%b %s\n' "${unicode_blue_circle}" "Delete requested (-D): removing existing container and image if present." >&2
		# Remove container if it exists
		local existing_container
		existing_container=$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)
		if [[ -n ${existing_container} ]]; then
			# Stop if running, then remove
			local running_container
			running_container=$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)
			if [[ -n ${running_container} ]]; then
				printf '%b %s\n' "${unicode_blue_circle}" "Stopping running container '${container_name}'..." >&2
				docker stop "${container_name}" >/dev/null 2>&1 || true
			fi
			printf '%b %s\n' "${unicode_blue_circle}" "Removing container '${container_name}'..." >&2
			docker rm -f "${container_name}" >/dev/null 2>&1 || true
		fi
		# Attempt to remove image by tag; ignore errors if not present or in use
		printf '%b %s\n\n' "${unicode_blue_circle}" "Removing image '${image_type}:${image_version}' (if present)..." >&2
		docker rmi -f "${image_type}:${image_version}" >/dev/null 2>&1 || true
		# Ensure we create a fresh container
		force_new=true
	fi

	# Check if container already exists and is not being forced to create new
	if [[ ${force_new} == false ]]; then
		local existing_container
		existing_container=$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)

		if [[ -n ${existing_container} ]]; then
			printf '%b %s\n' "${unicode_green_circle}" "Reusing existing container: ${existing_container}" >&2

			# Check if container is running
			local running_container
			running_container=$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)

			if [[ -z ${running_container} ]]; then
				printf '%b %s\n' "${unicode_blue_circle}" "Starting stopped container..." >&2
				docker start "${container_name}" >/dev/null || true
			fi

			# If still exists and running, attach; otherwise fall through to creation
			if [[ -n ${existing_container} ]]; then
				printf '%b %s\n' "${unicode_blue_circle}" "Attaching to container..." >&2

				# Try to detect user and workdir
				if [[ -n ${existing_container} ]]; then
					local rc=0
					if docker exec "${container_name}" id "${target_user}" >/dev/null 2>&1; then
						attach_shell "${target_user}" "/home/${target_user}" true || rc=$?
					else
						attach_shell "" /root true || rc=$?
					fi
					trap - EXIT
					return ${rc}
				fi
			fi
		fi
	else
		# Force new container - remove existing one if it exists
		local existing_container
		existing_container=$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)

		if [[ -n ${existing_container} ]]; then
			printf '%b %s\n' "${unicode_yellow_circle}" "Force new container requested - removing existing container: ${existing_container}" >&2

			# Stop container if it's running
			local running_container
			running_container=$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2>/dev/null)
			if [[ -n ${running_container} ]]; then
				printf '%b %s\n' "${unicode_blue_circle}" "Stopping running container..." >&2
				docker stop "${container_name}" >/dev/null
			fi

			# Remove the container
			printf '%b %s\n' "${unicode_blue_circle}" "Removing existing container..." >&2
			docker rm -f "${container_name}" >/dev/null 2>&1 || true
			printf '%b %s\n\n' "${unicode_green_circle}" "Container removed successfully" >&2
		fi
	fi

	local env_opts=(-e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	if [[ ${image_type} == "ubuntu" || ${image_type} == "debian" ]]; then
		env_opts+=(-e "LANG=C.UTF-8" -e "LANGUAGE=C.UTF-8" -e "LC_ALL=C.UTF-8" -e "DEBIAN_FRONTEND=noninteractive" -e "DEBCONF_NOWARNINGS=yes")
	fi

	# Run appropriate Docker container based on image type
	local docker_run_opts=(-it --platform "${docker_platform}" --name "${container_name}")
	if [[ ${auto_remove} == true ]]; then
		docker_run_opts+=(--rm)
	fi
	if [[ ${use_sudo} == false ]]; then
		docker_run_opts+=(--security-opt no-new-privileges)
	fi
	docker_run_opts+=("${env_opts[@]}")

	local pkgs_to_install=""
	if [[ ${use_sudo} == "true" ]]; then
		pkgs_to_install="sudo"
	fi
	if [[ -n ${additional_packages} ]]; then
		pkgs_to_install="${pkgs_to_install:+$pkgs_to_install }${additional_packages}"
	fi

	# --- Unified Setup Script ---
	# This script is executed inside the container to set up the environment.
	read -r -d '' setup_script <<EOM || true
set -e

# --- Package Installation ---
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -qq -y --no-install-recommends bash ca-certificates ${pkgs_to_install} >/dev/null 2>&1
    # Disable the 'command-not-found' handler that prints a sudo hint. This is often mistaken
    # for sudo's own lecture, but it's a separate system. Disabling it provides a cleaner shell.
    if [ -f /etc/bash.bashrc ]; then
        if [ -x /usr/lib/command-not-found ]; then
            chmod -x /usr/lib/command-not-found
        elif [ -x /usr/share/command-not-found/command-not-found ]; then
            chmod -x /usr/share/command-not-found/command-not-found
        fi
    fi
elif command -v apk >/dev/null 2>&1; then
    apk update -q >/dev/null 2>&1
    apk add -q --no-cache bash shadow ${pkgs_to_install} >/dev/null 2>&1
else
    echo "Unsupported package manager. Cannot install packages." >&2
    exit 1
fi

# --- User and Group Setup ---
if [ "${use_sudo}" = "true" ] || [ "${use_limited}" = "true" ]; then
    # Create group if it doesn't exist with the specified GID
    if ! getent group "${host_gid}" >/dev/null 2>&1; then
        groupadd -g "${host_gid}" "${target_user}" >/dev/null 2>&1
    fi

    # Create user if it doesn't exist with the specified UID
    if ! id -u "${target_user}" >/dev/null 2>&1; then
        # Docker bind mounts the volume to the home directory before this runs, so use --no-create-home
        useradd -o --shell /bin/bash -u "${host_uid}" -g "${host_gid}" --no-create-home -d "/home/${target_user}" "${target_user}" >/dev/null 2>&1
    else
        # If user exists, ensure UID and GID match the host.
        usermod -o -u "${host_uid}" -g "${host_gid}" "${target_user}" >/dev/null 2>&1
    fi

    # Grant passwordless sudo rights if requested
    if [ "${use_sudo}" = "true" ]; then
        mkdir -p /etc/sudoers.d
        echo "${target_user} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${target_user}"
        chmod 0440 "/etc/sudoers.d/${target_user}"

        # Append to /etc/sudoers to guarantee precedence and handle missing includedir
        echo "" >> /etc/sudoers
        echo "Defaults lecture=never" >> /etc/sudoers
        echo "${target_user} ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers

		# Also add user to the appropriate sudo/wheel group for robustness.
		if getent group sudo >/dev/null 2>&1; then
			usermod -aG sudo "${target_user}" >/dev/null 2>&1
			echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
		elif getent group wheel >/dev/null 2>&1; then
			# For Alpine/CentOS
			usermod -aG wheel "${target_user}" >/dev/null 2>&1
			echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
		fi
		
		# Suppress Ubuntu's default "To run a command as administrator" hint
		touch "/home/${target_user}/.sudo_as_admin_successful" >/dev/null 2>&1
    fi

    # Ensure home directory ownership is correct
    chown -R "${host_uid}:${host_gid}" "/home/${target_user}" >/dev/null 2>&1
fi
EOM

	# --- Container Execution ---
	local mount_path
	local work_dir
	if [[ ${use_sudo} == true || ${use_limited} == true ]]; then
		mount_path="/home/${target_user}"
		work_dir="/home/${target_user}"
	else
		mount_path="/root"
		work_dir="/root"
	fi

	if [[ ${auto_remove} == true ]]; then # Ephemeral
		local ephemeral_cmd="${setup_script}"
		if [[ ${use_sudo} == true || ${use_limited} == true ]]; then
			ephemeral_cmd+="; exec su -p ${target_user}"
			docker run "${docker_run_opts[@]}" -w "${work_dir}" -v "${volume_path}:${mount_path}" "${image_type}:${image_version}" sh -c "${ephemeral_cmd}"
		else
			ephemeral_cmd+="; exec bash"
			docker run "${docker_run_opts[@]}" -w "${work_dir}" -v "${volume_path}:${mount_path}" "${image_type}:${image_version}" sh -c "${ephemeral_cmd}"
		fi
	else # Persistent
		if ! docker ps -a --format '{{.Names}}' | grep -qx "${container_name}"; then
			local persistent_run_opts=(-d --init --platform "${docker_platform}" --name "${container_name}")
			if [[ ${use_sudo} == false ]]; then
				persistent_run_opts+=(--security-opt no-new-privileges)
			fi
			persistent_run_opts+=("${env_opts[@]}")
			docker run "${persistent_run_opts[@]}" -w "${work_dir}" -v "${volume_path}:${mount_path}" "${image_type}:${image_version}" tail -f /dev/null
		else
			docker start "${container_name}" >/dev/null || true
		fi

		docker exec "${container_name}" sh -c "${setup_script}" || {
			trap - EXIT
			printf '%b\n' "${unicode_red_circle} Error: Failed to setup persistent container." >&2
			return 1
		}

		local rc=0
		if [[ ${use_sudo} == true || ${use_limited} == true ]]; then
			attach_shell "${target_user}" "${work_dir}" true || rc=$?
		else
			attach_shell "" "${work_dir}" true || rc=$?
		fi
	fi
	trap - EXIT
	return ${rc}
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	_dh "$@"
fi
