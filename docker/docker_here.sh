#!/bin/bash

# Attach an interactive shell to a running container with bash->sh fallback.
_dh_attach_shell() {
	local container_name="$1"
	local user="$2"
	local workdir="$3"
	local prefer_bash="$4"
	local shell_cmd="sh"

	if [[ $prefer_bash == true ]] \
		&& docker exec "$container_name" sh -c 'command -v bash >/dev/null 2>&1' > /dev/null 2>&1; then
		shell_cmd="bash"
	fi

	# Allocate a pseudo-TTY only when stdin is a terminal
	local -a exec_opts=(-i)
	if [[ -t 0 ]]; then
		exec_opts=(-it)
	fi
	if [[ -n $user ]]; then
		exec_opts+=(-u "$user")
	fi
	if [[ -n $workdir ]] && docker exec "$container_name" test -d "$workdir" > /dev/null 2>&1; then
		exec_opts+=(-w "$workdir")
	fi

	docker exec "${exec_opts[@]}" "$container_name" "$shell_cmd"
}

_dh() {
	# Respect NO_COLOR, dumb terminals, and non-interactive stdout
	local enable_color=true
	if [[ -n ${NO_COLOR:-} || ${TERM:-} == "dumb" || ! -t 1 ]]; then
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

	if [[ $enable_color == false ]]; then
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

	local volume_path="$PWD"
	local raw_volume_path=""
	local volume_specified=false
	local docker_platform=""
	local image_type="alpine"  # default to alpine
	local image_version="edge" # default version for alpine
	local use_sudo=false
	local use_limited=false
	local force_new=false
	local auto_remove=false
	local quiet=false
	local delete_all=false
	local target_user="gh"
	local custom_user_set=false
	local additional_packages=""

	# Robust platform detection without dpkg (works on most Linux hosts)
	case "$(uname -m 2> /dev/null)" in
		x86_64 | amd64)
			docker_platform="linux/amd64"
			;;
		aarch64 | arm64)
			docker_platform="linux/arm64"
			;;
		armv7l | armv8l)
			docker_platform="linux/arm/v7"
			;;
		armv6l)
			docker_platform="linux/arm/v6"
			;;
		i386 | i686)
			docker_platform="linux/386"
			;;
		ppc64le)
			docker_platform="linux/ppc64le"
			;;
		riscv64)
			docker_platform="linux/riscv64"
			;;
		s390x)
			docker_platform="linux/s390x"
			;;
		*)
			docker_platform="linux/amd64" # sensible default
			;;
	esac

	# Parse arguments with getopts (leading ':' enables silent error handling for ':' and '?')
	local OPTIND=1
	local opt=""
	local -a parsed_opts=()
	while getopts ":aU:udDslP:p:i:v:hnrq" opt; do
		parsed_opts+=("$opt")
		case $opt in
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
				target_user="$OPTARG"
				custom_user_set=true
				;;
			P)
				additional_packages="$OPTARG"
				;;
			s)
				use_sudo=true
				;;
			l)
				use_limited=true
				;;
			p)
				docker_platform="$OPTARG"
				;;
			i)
				if [[ $OPTARG =~ ^(alpine|ubuntu|debian):([a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127})$ ]]; then
					image_type="${BASH_REMATCH[1]}"
					image_version="${BASH_REMATCH[2]}"
				else
					printf '\n%b %s\n' "$unicode_red_circle" "Error: Invalid image format '$OPTARG'. Use format: distro:version" >&2
					printf '\n%b %s\n\n' "$unicode_yellow_circle" "Examples: alpine:latest, ubuntu:22.04, debian:bullseye" >&2
					return 1
				fi
				;;
			v)
				if [[ -z $OPTARG ]]; then
					printf '%b %s\n' "$unicode_red_circle" "Error: -v requires a directory path" >&2
					return 1
				fi
				raw_volume_path="$OPTARG"
				volume_specified=true
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
				printf '\n%s\n' "Usage: _dh [OPTIONS]"
				printf '\n%s\n' "Options:"
				printf '%s\n' "  -a          Use Alpine Linux (default: edge)"
				printf '%s\n' "  -u          Use Ubuntu (default: latest)"
				printf '%s\n' "  -d          Use Debian (default: latest)"
				printf '%s\n' "  -s          Run with sudo privileges"
				printf '%s\n' "  -l          Run in limited mode (no sudo)"
				printf '%s\n' "  -p PLATFORM Set docker platform (default: auto-detect)"
				printf '%s\n' "  -U USER     Specify username in container (default: gh)"
				printf '%s\n' '  -P PKGS     Specify extra packages to install (e.g. "curl wget nano")'
				printf '%s\n' "  -i IMAGE    Specify image:version (e.g., alpine:3.18)"
				printf '%s\n' "  -v PATH     Create (if needed) and use PATH as volume (absolute, relative, or ~)"
				printf '%s\n' "  -n          Force create new container (don't reuse existing)"
				printf '%s\n' "  -r          Auto-remove container on exit (--rm)"
				printf '%s\n' "  -q          Quiet mode (suppress debug messages)"
				printf '%s\n\n' "  -D          Delete existing container and its image before starting"
				printf '%s\n\n' "  -h          Show this help message"
				return 0
				;;
			\?)
				printf '%s\n' "Error: Invalid option -${OPTARG}. Use -h for help." >&2
				return 1
				;;
			:)
				printf '%s\n' "Error: Option -${OPTARG} requires an argument." >&2
				return 1
				;;
		esac
	done

	# Shift past parsed options and reject unexpected positional arguments
	shift $((OPTIND - 1))
	if [[ $# -gt 0 ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Unexpected argument: '$1'. Use -h for help." >&2
		return 1
	fi

	# Emit option debug trace after parsing so -q works regardless of flag order
	if [[ $quiet == false ]]; then
		local parsed_opt
		for parsed_opt in "${parsed_opts[@]}"; do
			printf '\n%b %bDEBUG:%b Processing option: %b%s%b\n' \
				"$unicode_yellow_circle" "$color_yellow" "$color_end" "$color_magenta" "$parsed_opt" "$color_end" >&2
		done
	fi

	# Validate configuration conflicts
	if [[ $use_sudo == true && $use_limited == true ]]; then
		printf '%b %bERROR:%b %b-s%b (sudo) and %b-l%b (limited) options cannot be used together\n\n' \
			"$unicode_red_circle" "$color_red" "$color_end" "$color_magenta" "$color_end" "$color_magenta" "$color_end" >&2
		return 1
	fi

	# Security: Validate docker platform string
	if [[ ! $docker_platform =~ ^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+){1,2}$ ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid platform specified: '$docker_platform'" >&2
		return 1
	fi

	# Security: Validate username to prevent command injection and protect container root (UID 0)
	if [[ $target_user == "root" ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Username 'root' cannot be specified with -U; omit -s, -l, and -U to run as root." >&2
		return 1
	fi
	if [[ ! $target_user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid username specified: '$target_user'" >&2
		printf '%s\n' "Usernames must match the regex: ^[a-z_][a-z0-9_-]{0,31}$" >&2
		return 1
	fi

	# Security: Validate additional packages (reject newlines/control chars and validate every token)
	local -a pkg_array=()
	if [[ -n $additional_packages ]]; then
		if [[ $additional_packages =~ [[:cntrl:]] ]]; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid control characters in package list" >&2
			return 1
		fi
		local IFS=$' \t'
		read -r -a pkg_array <<< "$additional_packages"
		local pkg
		for pkg in "${pkg_array[@]}"; do
			if [[ ! $pkg =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]{0,127}$ ]]; then
				printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid package name specified: '$pkg'" >&2
				return 1
			fi
		done
	fi

	# Security: Resolve and strictly validate numeric host UID/GID (prevent arithmetic/command injection via SUDO_UID/SUDO_GID)
	local host_uid=""
	local host_gid=""
	if [[ -n ${SUDO_UID:-} ]]; then
		if [[ ! $SUDO_UID =~ ^[0-9]+$ ]]; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid SUDO_UID environment value: '$SUDO_UID'" >&2
			return 1
		fi
		host_uid="$SUDO_UID"
	else
		host_uid="$(id -u 2> /dev/null)" || {
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to determine host UID" >&2
			return 1
		}
	fi

	if [[ -n ${SUDO_GID:-} ]]; then
		if [[ ! $SUDO_GID =~ ^[0-9]+$ ]]; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Invalid SUDO_GID environment value: '$SUDO_GID'" >&2
			return 1
		fi
		host_gid="$SUDO_GID"
	else
		host_gid="$(id -g 2> /dev/null)" || {
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to determine host GID" >&2
			return 1
		}
	fi

	if [[ ! $host_uid =~ ^[0-9]+$ || ! $host_gid =~ ^[0-9]+$ ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Resolved host UID/GID must be numeric" >&2
		return 1
	fi
	if [[ $host_uid == "0" ]]; then host_uid="1000"; fi
	if [[ $host_gid == "0" ]]; then host_gid="1000"; fi

	if [[ $quiet == false ]]; then
		printf '\n%b %bDEBUG:%b Final values - %bimage_type=%b"%s"%b  %bimage_version=%b"%s"%b  %buse_sudo=%b"%s"%b  %badditional_packages=%b"%s"%b\n\n' \
			"$unicode_yellow_circle" "$color_yellow" "$color_end" \
			"$color_blue" "$color_green" "$image_type" "$color_end" \
			"$color_blue" "$color_green" "$image_version" "$color_end" \
			"$color_blue" "$color_green" "$use_sudo" "$color_end" \
			"$color_blue" "$color_green" "${pkg_array[*]}" "$color_end" >&2
	fi

	if [[ $custom_user_set == true && $use_sudo == false && $use_limited == false ]]; then
		printf '%b %bWARNING:%b %s\n\n' \
			"$unicode_yellow_circle" "$color_yellow" "$color_end" \
			"Custom user (-U $target_user) specified but no user mode (-s or -l) was enabled. Container will run as root." >&2
	fi

	# Ensure docker is available before performing host directory creation or container calls
	if ! command -v docker > /dev/null 2>&1; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Docker is not installed or not in PATH" >&2
		return 127
	fi

	# Resolve, validate, and create volume path after all flags are validated
	if [[ $volume_specified == true ]]; then
		local target_dir=""
		if [[ $raw_volume_path == /* ]]; then
			target_dir="$raw_volume_path"
		elif [[ $raw_volume_path == \~ || $raw_volume_path == \~/* ]]; then
			if [[ -z ${HOME:-} ]]; then
				printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Cannot expand '~': HOME is not set" >&2
				return 1
			fi
			target_dir="${HOME}${raw_volume_path#\~}"
		elif [[ $raw_volume_path == \~* ]]; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Unsupported tilde path '$raw_volume_path'. Use '~/...' or an explicit path." >&2
			return 1
		else
			target_dir="${PWD}/${raw_volume_path}"
		fi

		if [[ $target_dir == *:* || $target_dir =~ [[:cntrl:]] ]]; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Volume path cannot contain colons or control characters: '$target_dir'" >&2
			return 1
		fi

		if ! mkdir -p "$target_dir"; then
			printf '%b %s\n' "$unicode_red_circle" "Error: Failed to create directory '$target_dir'" >&2
			return 1
		fi
		volume_path="$target_dir"
	elif [[ $volume_path == *:* || $volume_path =~ [[:cntrl:]] ]]; then
		printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Volume path cannot contain colons or control characters: '$volume_path'" >&2
		return 1
	fi

	if [[ ! -d $volume_path ]]; then
		printf '%b %s\n' "$unicode_red_circle" "Error: Volume path '$volume_path' does not exist" >&2
		return 1
	fi

	if [[ ! -w $volume_path ]]; then
		local current_user
		current_user="$(id -un 2> /dev/null || printf '%s' 'unknown')"
		printf '%b %bWARNING:%b %s\n\n' \
			"$unicode_yellow_circle" "$color_yellow" "$color_end" \
			"Volume path '$volume_path' is not writable by user '$current_user'. Container operations may fail." >&2
	fi

	# Display container info
	printf '%b %b%bStarting %b%s%b:%b%s%b container...%b\n\n' \
		"$unicode_blue_circle" "$text_bold" "$color_gray" \
		"$color_blue" "$image_type" "$color_end" \
		"$color_green" "$image_version" "$color_end" "$color_end"
	if [[ $use_sudo == false && $use_limited == false ]]; then
		printf '%b Volume:   %b%s%b -> %b/root%b\n' \
			"$unicode_green_circle" "$color_magenta" "$volume_path" "$color_end" "$color_cyan" "$color_end"
	else
		printf '%b Volume:   %b%s%b -> %b/home/%s%b\n' \
			"$unicode_green_circle" "$color_magenta" "$volume_path" "$color_end" "$color_cyan" "$target_user" "$color_end"
	fi

	printf '%b Platform: %b%s%b\n' "$unicode_green_circle" "$color_magenta" "$docker_platform" "$color_end"
	[[ $use_sudo == true ]] && printf '%b Mode:     %bsudo%b\n' "$unicode_green_circle" "$color_magenta" "$color_end"
	[[ $use_limited == true ]] && printf '%b Mode:     %blimited%b (no sudo)\n' "$unicode_green_circle" "$color_magenta" "$color_end"
	[[ $use_sudo == false && $use_limited == false ]] && printf '%b Mode:     %broot%b\n' "$unicode_green_circle" "$color_magenta" "$color_end"
	[[ ${#pkg_array[@]} -gt 0 ]] && printf '%b Packages: %b%s%b\n' "$unicode_green_circle" "$color_magenta" "${pkg_array[*]}" "$color_end"
	printf '\n'

	# Generate sanitized container name from distro and current directory using pure Bash
	local dir_slug="${PWD##*/}"
	dir_slug="${dir_slug,,}"
	dir_slug="${dir_slug//[^a-z0-9_.-]/}"
	while [[ $dir_slug == [._-]* ]]; do
		dir_slug="${dir_slug#?}"
	done
	if [[ -z $dir_slug ]]; then
		dir_slug="workspace"
	fi
	local container_name="${image_type}_${dir_slug}"

	# If requested, delete existing container and its image before proceeding
	if [[ $delete_all == true ]]; then
		printf '%b %s\n' "$unicode_blue_circle" "Delete requested (-D): removing existing container and image if present." >&2
		local existing_container
		existing_container="$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}" 2> /dev/null)"
		if [[ -n $existing_container ]]; then
			local running_container
			running_container="$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2> /dev/null)"
			if [[ -n $running_container ]]; then
				printf '%b %s\n' "$unicode_blue_circle" "Stopping running container '$container_name'..." >&2
				docker stop "$container_name" > /dev/null 2>&1 || true
			fi
			printf '%b %s\n' "$unicode_blue_circle" "Removing container '$container_name'..." >&2
			docker rm -f "$container_name" > /dev/null 2>&1 || true
		fi
		printf '%b %s\n\n' "$unicode_blue_circle" "Removing image '${image_type}:${image_version}' (if present)..." >&2
		docker rmi -f "${image_type}:${image_version}" > /dev/null 2>&1 || true
		force_new=true
	fi

	# Reuse existing persistent container when neither -n (force_new) nor -r (auto_remove) is set
	local existing_container=""
	existing_container="$(docker ps -a --filter "name=^/${container_name}$" --format "{{.Names}}" 2> /dev/null)"

	if [[ $force_new == false && $auto_remove == false ]]; then
		if [[ -n $existing_container ]]; then
			printf '%b %s\n' "$unicode_green_circle" "Reusing existing container: $existing_container" >&2

			local running_container
			running_container="$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2> /dev/null)"

			if [[ -z $running_container ]]; then
				printf '%b %s\n' "$unicode_blue_circle" "Starting stopped container..." >&2
				if ! docker start "$container_name" > /dev/null; then
					printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to start existing container '$container_name'." >&2
					return 1
				fi
			fi

			if [[ ${#pkg_array[@]} -gt 0 ]]; then
				local reuse_pkgs="${pkg_array[*]}"
				if ! docker exec "$container_name" sh -c "if command -v apt-get >/dev/null 2>&1; then apt-get update -qq >/dev/null && apt-get install -qq -y --no-install-recommends ${reuse_pkgs} >/dev/null; elif command -v apk >/dev/null 2>&1; then apk add -q --no-cache ${reuse_pkgs} >/dev/null; fi"; then
					printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to install packages in existing container '$container_name'." >&2
					return 1
				fi
			fi

			printf '%b %s\n' "$unicode_blue_circle" "Attaching to container..." >&2
			local rc=0
			if docker exec "$container_name" id -u "$target_user" > /dev/null 2>&1; then
				_dh_attach_shell "$container_name" "$target_user" "/home/$target_user" true || rc=$?
			else
				_dh_attach_shell "$container_name" "" "/root" true || rc=$?
			fi
			return "$rc"
		fi
	elif [[ $force_new == true && -n $existing_container ]]; then
		printf '%b %s\n' "$unicode_yellow_circle" "Force new container requested - removing existing container: $existing_container" >&2

		local running_container
		running_container="$(docker ps --filter "name=^/${container_name}$" --format "{{.Names}}" 2> /dev/null)"
		if [[ -n $running_container ]]; then
			printf '%b %s\n' "$unicode_blue_circle" "Stopping running container..." >&2
			if ! docker stop "$container_name" > /dev/null; then
				printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to stop existing container '$container_name'." >&2
				return 1
			fi
		fi

		printf '%b %s\n' "$unicode_blue_circle" "Removing existing container..." >&2
		if ! docker rm -f "$container_name" > /dev/null 2>&1; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to remove existing container '$container_name'." >&2
			return 1
		fi
		printf '%b %s\n\n' "$unicode_green_circle" "Container removed successfully" >&2
		existing_container=""
	fi

	local -a env_opts=(-e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	if [[ $image_type == "ubuntu" || $image_type == "debian" ]]; then
		env_opts+=(
			-e "LANG=C.UTF-8"
			-e "LANGUAGE=C.UTF-8"
			-e "LC_ALL=C.UTF-8"
			-e "DEBIAN_FRONTEND=noninteractive"
			-e "DEBCONF_NOWARNINGS=yes"
		)
	fi

	# Build validated package list strictly from validated array tokens
	local -a install_pkgs=()
	if [[ $use_sudo == true ]]; then
		install_pkgs+=("sudo")
	fi
	if [[ ${#pkg_array[@]} -gt 0 ]]; then
		install_pkgs+=("${pkg_array[@]}")
	fi
	local pkgs_to_install="${install_pkgs[*]}"

	# --- Unified Setup Script ---
	# Assembled modularly so only active setup sections run inside the container.
	# All interpolated values are strictly whitelist-validated above.
	local setup_script=""
	read -r -d '' setup_script << EOM || true
set -e

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null
    apt-get install -qq -y --no-install-recommends bash ca-certificates ${pkgs_to_install} >/dev/null
    if [ -f /etc/bash.bashrc ]; then
        if [ -x /usr/lib/command-not-found ]; then
            chmod -x /usr/lib/command-not-found
        elif [ -x /usr/share/command-not-found/command-not-found ]; then
            chmod -x /usr/share/command-not-found/command-not-found
        fi
        sed -i '/sudo_as_admin_successful/s/\[ ! -e/false \&\& [ ! -e/' /etc/bash.bashrc 2>/dev/null || true
    fi
elif command -v apk >/dev/null 2>&1; then
    apk add -q --no-cache bash ca-certificates shadow ${pkgs_to_install} >/dev/null
else
    printf '%s\n' "Unsupported package manager. Cannot install packages." >&2
    exit 1
fi
EOM

	if [[ $use_sudo == true || $use_limited == true ]]; then
		local user_setup_script=""
		read -r -d '' user_setup_script << EOM || true
# Move any pre-existing non-root placeholder account (e.g. ubuntu:24.04 UID 1000) off host_uid
existing_uid_user=\$(awk -F: -v uid="${host_uid}" '\$3 == uid && \$1 != "root" && \$1 != "${target_user}" { print \$1; exit }' /etc/passwd)
if [ -n "\${existing_uid_user}" ]; then
    usermod -u 65533 "\${existing_uid_user}" >/dev/null 2>&1 || true
fi

# Ensure group with host_gid exists (handle both missing GID and existing group name)
if ! grep -qE "^[^:]+:[^:]*:${host_gid}:" /etc/group; then
    if grep -qE "^${target_user}:" /etc/group; then
        groupmod -o -g "${host_gid}" "${target_user}" >/dev/null 2>&1
    else
        groupadd -o -g "${host_gid}" "${target_user}" >/dev/null 2>&1
    fi
fi

# Create or update target user with matching host UID/GID (--no-create-home since volume is already mounted)
if ! id -u "${target_user}" >/dev/null 2>&1; then
    useradd -o --shell /bin/bash -u "${host_uid}" -g "${host_gid}" --no-create-home -d "/home/${target_user}" "${target_user}" >/dev/null 2>&1
else
    usermod -o --shell /bin/bash -u "${host_uid}" -g "${host_gid}" -d "/home/${target_user}" "${target_user}" >/dev/null 2>&1
fi
EOM
		setup_script+=$'\n'"$user_setup_script"

		if [[ $use_sudo == true ]]; then
			local sudo_setup_script=""
			read -r -d '' sudo_setup_script << EOM || true
mkdir -p /etc/sudoers.d
printf '%s\n' "Defaults lecture=never" "${target_user} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${target_user}"
chmod 0440 "/etc/sudoers.d/${target_user}"

if [ -f /etc/sudoers ] && ! grep -qE '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers; then
    printf '\n#includedir /etc/sudoers.d\n' >> /etc/sudoers
fi

if grep -qE '^sudo:' /etc/group; then
    usermod -aG sudo "${target_user}" >/dev/null 2>&1 || true
elif grep -qE '^wheel:' /etc/group; then
    usermod -aG wheel "${target_user}" >/dev/null 2>&1 || true
fi
EOM
			setup_script+=$'\n'"$sudo_setup_script"
		fi

		local home_setup_script=""
		read -r -d '' home_setup_script << EOM || true
# Ensure top-level home mount ownership without recursively modifying host files or following symlinks
mkdir -p "/home/${target_user}"
chown -h "${host_uid}:${host_gid}" "/home/${target_user}" 2>/dev/null || true
EOM
		setup_script+=$'\n'"$home_setup_script"
	fi

	# --- Container Execution ---
	local mount_path="/root"
	local work_dir="/root"
	if [[ $use_sudo == true || $use_limited == true ]]; then
		mount_path="/home/$target_user"
		work_dir="/home/$target_user"
	fi

	local rc=0
	if [[ $auto_remove == true ]]; then
		# Avoid colliding with an existing persistent container when -r is used without -n
		local ephemeral_name="$container_name"
		if [[ -n $existing_container ]]; then
			ephemeral_name="${container_name}_ephemeral_$$"
		fi

		local -a docker_run_opts=(-i)
		if [[ -t 0 ]]; then
			docker_run_opts=(-it)
		fi
		docker_run_opts+=(--init --rm --platform "$docker_platform" --name "$ephemeral_name")
		if [[ $use_sudo == false ]]; then
			docker_run_opts+=(--security-opt no-new-privileges)
		fi
		docker_run_opts+=("${env_opts[@]}")

		local ephemeral_cmd="$setup_script"
		if [[ $use_sudo == true || $use_limited == true ]]; then
			ephemeral_cmd+=$'\n'"exec su -s /bin/bash \"${target_user}\""
		else
			ephemeral_cmd+=$'\n'"exec bash"
		fi
		docker run "${docker_run_opts[@]}" -w "$work_dir" -v "${volume_path}:${mount_path}" "${image_type}:${image_version}" sh -c "$ephemeral_cmd" || rc=$?
	else
		local -a persistent_run_opts=(-d --init --platform "$docker_platform" --name "$container_name")
		if [[ $use_sudo == false ]]; then
			persistent_run_opts+=(--security-opt no-new-privileges)
		fi
		persistent_run_opts+=("${env_opts[@]}")

		if ! docker run "${persistent_run_opts[@]}" -w "$work_dir" -v "${volume_path}:${mount_path}" "${image_type}:${image_version}" tail -f /dev/null > /dev/null; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to create persistent container '$container_name'." >&2
			return 1
		fi

		if ! docker exec "$container_name" sh -c "$setup_script"; then
			printf '%b %bERROR:%b %s\n' "$unicode_red_circle" "$color_red" "$color_end" "Failed to setup persistent container '$container_name'." >&2
			return 1
		fi

		if [[ $use_sudo == true || $use_limited == true ]]; then
			_dh_attach_shell "$container_name" "$target_user" "$work_dir" true || rc=$?
		else
			_dh_attach_shell "$container_name" "" "$work_dir" true || rc=$?
		fi
	fi

	return "$rc"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	_dh "$@"
fi
