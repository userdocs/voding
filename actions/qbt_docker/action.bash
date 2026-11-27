#!/bin/bash
#
# Docker Container Action Script
#
# This script creates and manages Docker containers for GitHub Actions with:
# - Multi-architecture platform support (auto-detected or specified)
# - Security hardening and input validation
# - Custom package installation support
# - Environment variable sanitization
# - Custom Dockerfile support
#
# Security Features:
# - Input validation and sanitization for all user inputs
# - Prevention of command injection, flag injection, and path/symlink traversal
# - GitHub environment variable protection
# - Docker security options (capability restrictions, optional non-root execution)
# - Optional resource limits via whitelisted custom Docker flags (--memory, --cpus)
#
# Platform Support:
# - Automatic platform detection from runner architecture
# - Support for arch-prefixed images (e.g., arm64v8/alpine:edge)
# - Platform format validation

#=============================================================================
# CONFIGURATION AND CONSTANTS
#=============================================================================

# Config (env-overridable)
inputs_dockerfile="${inputs_dockerfile:-}"
inputs_use_host_env="${inputs_use_host_env:-false}"
inputs_use_root="${inputs_use_root:-false}"
inputs_os_id="${inputs_os_id:-alpine}"
inputs_os_version_id="${inputs_os_version_id:-edge}"
inputs_custom_docker_commands="${inputs_custom_docker_commands:-}"
inputs_additional_apps="${inputs_additional_apps:-}"
inputs_platform="${inputs_platform:-}"
# Runner architecture is provided by GitHub Actions as an external env var.
# shellcheck disable=SC2153
runner_arch="${RUNNER_ARCH:-}"

# These variables are locked readonly during direct script execution; kept mutable on source for idempotent testing.
container_name="qbt_builder"
# wd is not readonly: the fast-path may override it from a Dockerfile WORKDIR instruction.
wd="/home/gh"
non_root_user="gh"
non_root_uid="1001"
non_root_gid="1001"
workspace="${GITHUB_WORKSPACE:-$PWD}"

# Declare arrays and variables early
declare -a docker_command=()
declare -a clean_envs=()
declare -a inputs_additional_apps_array=()
declare -a inputs_custom_docker_commands_array=()
declare dockerfile_path=""
declare custom_image_tag=""
declare env_custom=""

#=============================================================================
# LOGGING FUNCTIONS
#=============================================================================

log_info() {
	printf '[INFO] %s\n' "$1"
}

log_error() {
	printf '[ERROR] %s\n' "$1" >&2
}

log_debug() {
	printf '[DEBUG] %s\n' "$1"
}

log_warn() {
	printf '[WARN] %s\n' "$1" >&2
}

#=============================================================================
# VALIDATION FUNCTIONS
#=============================================================================

# Return a safe identifier for logging blocked or sensitive env entries without leaking values
redact_env_var() {
	local LC_ALL=C
	local input="${1%%[$'\r\n']*}"
	if [[ $input =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
		printf '%s=<redacted>' "${BASH_REMATCH[1]}"
	else
		printf '<malformed-env-entry>'
	fi
}

# Format clean_envs for safe logging/summaries while redacting -e / --env values
format_clean_envs_for_log() {
	local -a formatted=()
	local i=0
	local flag
	local val

	while [[ $i -lt ${#clean_envs[@]} ]]; do
		flag="${clean_envs[i]}"
		val="${clean_envs[i + 1]:-}"
		if [[ $flag == "-e" || $flag == "--env" ]]; then
			formatted+=("$flag" "$(redact_env_var "$val")")
		else
			formatted+=("$flag" "$val")
		fi
		i=$((i + 2))
	done
	printf '%s' "${formatted[*]}"
}

# Non-exiting check for environment variable format and blocklist
check_env_var() {
	local LC_ALL=C
	local input="$1"

	# Reject embedded newlines or carriage returns (Bash =~ '.' matches '\n')
	if [[ $input == *$'\n'* || $input == *$'\r'* ]]; then
		return 1
	fi

	# Validate environment variable format and block dangerous shell, loader, and GitHub runner vars.
	# LD_, DYLD_, and BASH_ are prefix-matched to catch LD_PRELOAD, BASH_ENV, etc.
	if [[ ! $input =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] \
		|| [[ $input =~ ^(PATH|SHELL|HOME|ENV|IFS|CDPATH|PROMPT_COMMAND|PS4|SHELLOPTS|BASHOPTS|GLIBC_TUNABLES|GCONV_PATH|GITHUB_ENV|GITHUB_OUTPUT|GITHUB_PATH|GITHUB_STEP_SUMMARY|GITHUB_STATE)= ]] \
		|| [[ $input =~ ^(LD_|DYLD_|BASH_) ]]; then
		return 1
	fi

	# Check for dangerous characters using case
	case "$input" in
		*\;* | *\&* | *\|* | *\<* | *\>* | *\`* | *\$\(*)
			return 1
			;;
	esac

	return 0
}

# Security input validation functions
validate_input() {
	local LC_ALL=C
	local input="$1"
	local type="$2"

	case "$type" in
		"docker_arg")
			# Only allow safe docker arguments - whitelist approach
			if [[ ! $input =~ ^(-[evuw]|--env|--volume|--user|--workdir|--memory|--cpus)$ ]]; then
				log_error "Security: Invalid docker argument blocked: $input"
				exit 1
			fi
			;;
		"package_name")
			# Validate package names (must start with ASCII alphanumeric to prevent CLI flag injection)
			if [[ ! $input =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]] || [[ ${#input} -gt 128 ]]; then
				log_error "Security: Invalid package name blocked: $input"
				exit 1
			fi
			;;
		"dockerfile_path")
			# Restrict to workspace-relative paths only, no '..' path segments, leading '/', or leading '-'
			if [[ $input =~ (^|/)\.\.(/|$)|^/|^-|// ]] || [[ ${#input} -gt 256 ]] || [[ ! $input =~ ^[a-zA-Z0-9._/-]+$ ]]; then
				log_error "Security: Invalid dockerfile path blocked: $input"
				exit 1
			fi
			;;
		"env_var")
			if ! check_env_var "$input"; then
				log_error "Security: Invalid environment variable blocked: $(redact_env_var "$input")"
				exit 1
			fi
			;;
		"platform")
			# Validate Docker platform format
			if [[ ! $input =~ ^[a-z]+/[a-z0-9]+(/v[0-9]+)?$ ]] || [[ ${#input} -gt 32 ]]; then
				log_error "Security: Invalid platform format blocked: $input"
				exit 1
			fi
			;;
		"docker_volume")
			# Validate volume mount format; block traversal, option injection, whitespace, and Docker socket mounts
			if [[ ! $input =~ ^[a-zA-Z0-9._/,:+-]+$ ]] \
				|| [[ ! $input =~ ^[^:]+(:[^:]+(:[a-zA-Z0-9,._-]+)?)?$ ]] \
				|| [[ $input =~ ^-|(^|/|:)\.\.(/|:|$)|(^|/|:)docker\.sock(/|:|$) ]] \
				|| [[ ${#input} -gt 512 ]]; then
				log_error "Security: Invalid docker volume specification blocked: $input"
				exit 1
			fi
			;;
		"docker_user")
			if [[ ! $input =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*(:[a-zA-Z0-9_][a-zA-Z0-9_.-]*)?$ ]] || [[ ${#input} -gt 64 ]]; then
				log_error "Security: Invalid docker user specification blocked: $input"
				exit 1
			fi
			;;
		"docker_workdir")
			if [[ ! $input =~ ^/[a-zA-Z0-9._/-]*$ ]] || [[ $input =~ (^|/)\.\.(/|$) ]] || [[ ${#input} -gt 256 ]]; then
				log_error "Security: Invalid docker workdir specification blocked: $input"
				exit 1
			fi
			;;
		"docker_memory")
			if [[ ! $input =~ ^[1-9][0-9]*[bBkKmMgG]?$ ]] || [[ ${#input} -gt 32 ]]; then
				log_error "Security: Invalid docker memory specification blocked: $input"
				exit 1
			fi
			;;
		"docker_cpus")
			if [[ ! $input =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ ! $input =~ [1-9] ]] || [[ ${#input} -gt 16 ]]; then
				log_error "Security: Invalid docker cpus specification blocked: $input"
				exit 1
			fi
			;;
		*)
			log_error "Security: Unknown validation type: $type"
			exit 1
			;;
	esac
}

# Verify a workspace-relative file contains no symbolic link components and stays within $workspace.
# Returns: 0 = safe regular file, 1 = security violation (logged), 2 = file missing / not a regular file.
validate_workspace_file() {
	local rel_path="$1"
	local ws_real
	local target_dir_real
	local parent_dir
	local current_path="$workspace"
	local part
	local IFS='/'
	local -a parts

	if [[ -z $rel_path || $rel_path == /* || $rel_path == *$'\n'* || $rel_path == *$'\r'* ]]; then
		log_error "Security: Invalid workspace-relative path: $rel_path"
		return 1
	fi

	ws_real=$(cd -P -- "$workspace" 2> /dev/null && pwd -P) || {
		log_error "Security: Unable to resolve workspace path: $workspace"
		return 1
	}

	read -ra parts <<< "$rel_path"
	for part in "${parts[@]}"; do
		[[ -z $part || $part == "." ]] && continue
		current_path="${current_path}/${part}"
		if [[ -L $current_path ]]; then
			log_error "Security: Symbolic links are not allowed in workspace path: $rel_path"
			return 1
		fi
	done

	if [[ ! -f $current_path ]]; then
		return 2
	fi

	parent_dir="${current_path%/*}"
	[[ -z $parent_dir ]] && parent_dir="/"
	target_dir_real=$(cd -P -- "$parent_dir" 2> /dev/null && pwd -P) || {
		log_error "Security: Unable to resolve file directory: $rel_path"
		return 1
	}
	if [[ $target_dir_real != "$ws_real" && $target_dir_real != "${ws_real%/}/"* ]]; then
		log_error "Security: Path escapes workspace boundary: $rel_path"
		return 1
	fi

	return 0
}

# Validate Docker commands against whitelist
validate_docker_commands() {
	local cmd_line
	local -a tokens

	for cmd_line in "${inputs_custom_docker_commands_array[@]}"; do
		[[ -z ${cmd_line//[[:space:]]/} ]] && continue

		read -ra tokens <<< "$cmd_line"
		if [[ ${#tokens[@]} -gt 0 ]]; then
			validate_input "${tokens[0]}" "docker_arg"
			if [[ ${#tokens[@]} -lt 2 ]]; then
				log_error "Security: Docker argument missing value: ${tokens[0]}"
				exit 1
			fi
		fi
	done
}

# Validate basic inputs
validate_basic_inputs() {
	local LC_ALL=C

	# Validate boolean inputs
	if [[ ! $inputs_use_host_env =~ ^(true|false)$ ]]; then
		log_error "Security: inputs_use_host_env must be 'true' or 'false', got: $inputs_use_host_env"
		exit 1
	fi
	if [[ ! $inputs_use_root =~ ^(true|false)$ ]]; then
		log_error "Security: inputs_use_root must be 'true' or 'false', got: $inputs_use_root"
		exit 1
	fi

	# Validate workspace directory (must be an existing absolute host path without ':' or newlines)
	if [[ -z $workspace || $workspace != /* || ! -d $workspace || $workspace == *:* || $workspace == *$'\n'* || $workspace == *$'\r'* ]]; then
		log_error "Security: Invalid or missing workspace directory: $workspace"
		exit 1
	fi

	# Reject symbolic links on GitHub Actions runner file targets
	if [[ -n ${GITHUB_ENV:-} && -L $GITHUB_ENV ]]; then
		log_error "Security: GITHUB_ENV must not be a symbolic link"
		exit 1
	fi
	if [[ -n ${GITHUB_OUTPUT:-} && -L $GITHUB_OUTPUT ]]; then
		log_error "Security: GITHUB_OUTPUT must not be a symbolic link"
		exit 1
	fi
	if [[ -n ${GITHUB_STEP_SUMMARY:-} && -L $GITHUB_STEP_SUMMARY ]]; then
		log_error "Security: GITHUB_STEP_SUMMARY must not be a symbolic link"
		exit 1
	fi

	# Validate os_id format (OCI image name: starts/ends alphanumeric, no '//' or '..' segments)
	if [[ ! $inputs_os_id =~ ^[a-zA-Z0-9]([a-zA-Z0-9._/-]*[a-zA-Z0-9])?$ ]] \
		|| [[ $inputs_os_id =~ //|(^|/)\.\.(/|$) ]] \
		|| [[ ${#inputs_os_id} -gt 128 ]]; then
		log_error "Security: Invalid inputs_os_id format: $inputs_os_id"
		exit 1
	fi

	# Validate os_version_id format (OCI tag: starts with alphanumeric or underscore)
	if [[ ! $inputs_os_version_id =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]] || [[ ${#inputs_os_version_id} -gt 64 ]]; then
		log_error "Security: Invalid inputs_os_version_id format: $inputs_os_version_id"
		exit 1
	fi

	# Validate platform input for security
	validate_input "$inputs_platform" "platform"
}

#=============================================================================
# PLATFORM AND OS DETECTION FUNCTIONS
#=============================================================================

# Detect OS type from Docker image labels
detect_image_os() {
	local image="$1"
	local detected_os=""

	log_debug "Detecting OS type for image: $image" >&2

	# Check if required tools are available
	if ! command -v docker > /dev/null 2>&1; then
		log_debug "Docker not available, using image name fallback" >&2
		detected_os=$(detect_os_fallback "$image")
	elif ! command -v jq > /dev/null 2>&1; then
		log_debug "jq not available, using image name fallback" >&2
		detected_os=$(detect_os_fallback "$image")
	else
		# Get the raw JSON first to avoid complex jq parsing in a single command
		local docker_inspect_json
		docker_inspect_json=$(docker buildx imagetools inspect --format '{{json .}}' -- "$image" 2> /dev/null)

		if [[ -n $docker_inspect_json ]]; then
			# Section 1: GHCR userdocs-specific metadata parsing
			detected_os=$(detect_os_userdocs "$docker_inspect_json")

			# Section 2: Official Docker images detection
			if [[ -z $detected_os ]]; then
				detected_os=$(detect_os_official "$docker_inspect_json" "$image")
			fi

			# Section 3: Fallback detection with combined checks
			if [[ -z $detected_os ]]; then
				detected_os=$(detect_os_fallback_with_metadata "$docker_inspect_json" "$image")
			fi
		else
			log_debug "Failed to inspect image with docker buildx" >&2
			detected_os=$(detect_os_fallback "$image")
		fi
	fi

	# Final safety fallback
	if [[ -z $detected_os ]]; then
		detected_os="unknown"
	fi

	log_debug "Detected OS: $detected_os" >&2
	printf '%s' "$detected_os"
}

# Section 1: GHCR userdocs-specific metadata parsing
detect_os_userdocs() {
	local LC_ALL=C
	local docker_inspect_json="$1"
	local detected_os=""

	log_debug "Checking for GHCR userdocs metadata" >&2

	# Support single-arch (.image.config.Labels) and multi-arch (.image[platform].config.Labels), skipping empty attestation entries
	local labels_query='((.image | if type == "object" and (has("config") or has("history")) then . else ([.[]? | select(type == "object" and (has("config") or has("history")))][0] // {}) end).config.Labels // {})'
	local base_id
	local base_name
	base_id=$(jq -r "try (${labels_query}.\"org.opencontainers.image.base.id\" // \"\")" <<< "$docker_inspect_json" 2> /dev/null)
	base_name=$(jq -r "try (${labels_query}.\"org.opencontainers.image.base.name\" // \"\")" <<< "$docker_inspect_json" 2> /dev/null)

	if [[ -n $base_id && $base_id != "null" ]]; then
		log_debug "Found userdocs base.id: $base_id" >&2
		case "${base_id,,}" in
			alpine)
				detected_os="alpine"
				;;
			debian)
				detected_os="debian"
				;;
			ubuntu)
				detected_os="ubuntu"
				;;
		esac
	elif [[ -n $base_name && $base_name != "null" ]]; then
		log_debug "Found userdocs base.name: $base_name" >&2
		# Parse base.name (e.g., "alpine:edge")
		local base_os
		base_os="${base_name%%:*}" # Extract part before :
		base_os="${base_os##*/}"   # Extract part after last / (in case of registry prefix)
		case "${base_os,,}" in
			alpine)
				detected_os="alpine"
				;;
			debian)
				detected_os="debian"
				;;
			ubuntu)
				detected_os="ubuntu"
				;;
		esac
	fi

	[[ -n $detected_os ]] && log_debug "Userdocs detection result: $detected_os" >&2
	printf '%s' "$detected_os"
}

# Section 2: Official Docker images detection
detect_os_official() {
	local LC_ALL=C
	local docker_inspect_json="$1"
	local image="$2"
	local detected_os=""

	log_debug "Checking for official Docker image patterns" >&2

	# Check URL metadata for official Docker images
	local labels_query='((.image | if type == "object" and (has("config") or has("history")) then . else ([.[]? | select(type == "object" and (has("config") or has("history")))][0] // {}) end).config.Labels // {})'
	local image_url
	image_url=$(jq -r "try (${labels_query}.\"org.opencontainers.image.url\" // \"\")" <<< "$docker_inspect_json" 2> /dev/null)

	if [[ -n $image_url && $image_url != "null" ]]; then
		log_debug "Found image URL: $image_url" >&2

		case "${image_url,,}" in
			*hub.docker.com/_/alpine*)
				detected_os="alpine"
				;;
			*hub.docker.com/_/debian*)
				detected_os="debian"
				;;
			*hub.docker.com/_/ubuntu*)
				detected_os="ubuntu"
				;;
		esac
	fi

	# Secondary check: parse image name for official format
	if [[ -z $detected_os ]]; then
		local image_name
		image_name=$(jq -r 'try (.name // "")' <<< "$docker_inspect_json" 2> /dev/null)
		[[ -z $image_name || $image_name == "null" ]] && image_name="$image"

		if [[ -n $image_name ]]; then
			log_debug "Checking image name: $image_name" >&2

			# Handle Docker Hub registry/library and arch-prefixed images (e.g., docker.io/library/alpine:edge, arm64v8/alpine:edge)
			local base_name="${image_name,,}"
			base_name="${base_name#docker.io/}"
			if [[ $base_name =~ ^(library|amd64|i386|arm32v6|arm32v7|arm64v8|ppc64le|s390x|riscv64)/(.+)$ ]]; then
				base_name="${BASH_REMATCH[2]}"
				log_debug "Detected official/arch-prefixed image, using base: $base_name" >&2
			fi

			# Extract the base OS name (first part before :)
			local os_part="${base_name%%:*}"
			case "$os_part" in
				alpine)
					detected_os="alpine"
					;;
				debian)
					detected_os="debian"
					;;
				ubuntu)
					detected_os="ubuntu"
					;;
			esac
		fi
	fi

	[[ -n $detected_os ]] && log_debug "Official Docker detection result: $detected_os" >&2
	printf '%s' "$detected_os"
}

# Section 3: Fallback detection with metadata and name parsing
detect_os_fallback_with_metadata() {
	local LC_ALL=C
	local docker_inspect_json="$1"
	local image="$2"
	local detected_os=""

	log_debug "Using fallback detection with metadata" >&2

	# Check history for OS hints (supports single-arch and multi-arch schemas; word-bounded to ignore DEBIAN_FRONTEND)
	local image_query='(.image | if type == "object" and (has("config") or has("history")) then . else ([.[]? | select(type == "object" and (has("config") or has("history")))][0] // {}) end)'
	local history_check
	history_check=$(jq -r "try ((${image_query}.history // [])[].created_by // \"\")" <<< "$docker_inspect_json" 2> /dev/null | LC_ALL=C grep -i -E '(^|[^a-zA-Z0-9_])(alpine|debian|ubuntu)([^a-zA-Z0-9_]|$)' | head -1)

	if [[ -n $history_check ]]; then
		log_debug "Found OS in history: $history_check" >&2
		case "${history_check,,}" in
			*alpine*)
				detected_os="alpine"
				;;
			*debian*)
				detected_os="debian"
				;;
			*ubuntu*)
				detected_os="ubuntu"
				;;
		esac
	fi

	# If still no match, use name parsing fallback
	if [[ -z $detected_os ]]; then
		detected_os=$(detect_os_fallback "$image")
	fi

	[[ -n $detected_os ]] && log_debug "Fallback with metadata result: $detected_os" >&2
	printf '%s' "$detected_os"
}

# Final fallback: name parsing only
detect_os_fallback() {
	local LC_ALL=C
	local image="$1"
	local detected_os=""
	local part

	log_debug "Using name-only fallback detection" >&2

	# Strip optional docker.io/ and known official/arch prefixes without discarding org names (e.g., alpine/git)
	local base_image="${image,,}"
	base_image="${base_image#docker.io/}"
	if [[ $base_image =~ ^(library|amd64|i386|arm32v6|arm32v7|arm64v8|ppc64le|s390x|riscv64)/(.+)$ ]]; then
		base_image="${BASH_REMATCH[2]}"
		log_debug "Detected official/arch-prefixed image, using base: $base_image" >&2
	fi

	# Split on common separators and check each part
	local IFS=$':-_/'
	local -a name_parts
	read -ra name_parts <<< "$base_image"

	for part in "${name_parts[@]}"; do
		case "${part,,}" in
			*alpine*)
				detected_os="alpine"
				break
				;;
			*debian*)
				detected_os="debian"
				break
				;;
			*ubuntu*)
				detected_os="ubuntu"
				break
				;;
		esac
	done

	[[ -n $detected_os ]] && log_debug "Name-only fallback result: $detected_os" >&2
	printf '%s' "$detected_os"
}

# Parse arch-prefixed image names and set platform
setup_platform() {
	local LC_ALL=C
	local arch_prefix
	local image_name

	# Parse arch-prefixed image names (e.g., arm64v8/alpine:edge) and set platform
	# Only match known architecture prefixes to avoid parsing registry URLs
	if [[ $inputs_os_id =~ ^(amd64|i386|arm32v6|arm32v7|arm64v8|ppc64le|s390x|riscv64)/(.+)$ ]]; then
		arch_prefix="${BASH_REMATCH[1]}"
		image_name="${BASH_REMATCH[2]}"

		# Validate image name for security
		if [[ ! $image_name =~ ^[a-zA-Z0-9]([a-zA-Z0-9._/-]*[a-zA-Z0-9])?$ ]] \
			|| [[ $image_name =~ //|(^|/)\.\.(/|$) ]] \
			|| [[ ${#image_name} -gt 128 ]]; then
			log_error "Security: Invalid image name format: $image_name"
			exit 1
		fi

		if [[ -z $inputs_platform ]]; then
			case "$arch_prefix" in
				"amd64") inputs_platform="linux/amd64" ;;
				"i386") inputs_platform="linux/i386" ;;
				"arm32v6") inputs_platform="linux/arm/v6" ;;
				"arm32v7") inputs_platform="linux/arm/v7" ;;
				"arm64v8") inputs_platform="linux/arm64" ;;
				"ppc64le") inputs_platform="linux/ppc64le" ;;
				"s390x") inputs_platform="linux/s390x" ;;
				"riscv64") inputs_platform="linux/riscv64" ;;
			esac

			# Keep the full arch-prefixed image name - Docker needs it to pull the correct variant
			log_debug "Detected arch-prefixed image: $inputs_os_id -> platform: $inputs_platform"
		fi
	fi

	# Set default platform based on runner architecture only if inputs_platform is still empty/null/unset
	if [[ -z ${inputs_platform} ]]; then
		case "${runner_arch:-}" in
			"X86") inputs_platform="linux/i386" ;;
			"X64") inputs_platform="linux/amd64" ;;
			"ARM") inputs_platform="linux/arm/v7" ;;
			"ARM64") inputs_platform="linux/arm64" ;;
			*) inputs_platform="linux/amd64" ;; # fallback to amd64
		esac
		log_debug "Using runner architecture detection: ${runner_arch:-unknown} -> platform: $inputs_platform"
	fi
}

#=============================================================================
# ENVIRONMENT PROCESSING FUNCTIONS
#=============================================================================

# Filter valid env vars from stdin to stdout, blocking dangerous entries
_sanitize_env_stream() {
	local line

	while IFS= read -r line || [[ -n $line ]]; do
		line="${line%$'\r'}"
		[[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
		# Use centralized validation without subshell fork
		if check_env_var "$line"; then
			printf '%s\n' "$line"
		else
			log_error "Security: Invalid environment variable blocked: $(redact_env_var "$line")"
		fi
	done
}

# Sanitize environment files
sanitize_env_file() {
	local input_file="$1"
	local output_file="$2"

	if [[ -f $input_file ]]; then
		_sanitize_env_stream < "$input_file" > "$output_file"
	fi
}

# Validate workspace environment file paths upfront before building images
validate_environment_paths() {
	if [[ -d "${workspace}/env.load" && ! -L "${workspace}/env.load" ]]; then
		log_error "Failed to prepare environment file: ${workspace}/env.load is a directory"
		exit 1
	fi
	if [[ -L "${workspace}/env.custom" ]]; then
		log_error "Security: Symbolic links are not allowed in workspace path: env.custom"
		exit 1
	fi
	if [[ -f "${workspace}/env.custom" && ! -r "${workspace}/env.custom" ]]; then
		log_error "Failed to read custom environment file: ${workspace}/env.custom"
		exit 1
	fi
	if [[ $inputs_use_host_env == 'true' && -d "${workspace}/env.host" && ! -L "${workspace}/env.host" ]]; then
		log_error "Failed to write host environment: ${workspace}/env.host is a directory"
		exit 1
	fi
}

# Process environment configuration
process_environment() {
	local use_host=false
	local entry

	validate_environment_paths

	# Ensure no stale env.load or intermediate files are carried over
	rm -f "${workspace}/env.load" "${workspace}/env.host.safe" "${workspace}/env.custom.safe"

	if [[ $inputs_use_host_env == 'true' ]]; then
		rm -f "${workspace}/env.host"
		(
			umask 077
			while IFS= read -r -d '' entry; do
				[[ $entry != *$'\n'* && $entry != *$'\r'* ]] && printf '%s\n' "$entry"
			done < <(env -0) > "${workspace}/env.host"
		) || {
			log_error "Failed to write host environment to ${workspace}/env.host"
			exit 1
		}
		log_info "Security: Host environment dumped - review for sensitive data"
		use_host=true
	fi

	if [[ $use_host == true && -f "${workspace}/env.custom" ]]; then
		(
			umask 077
			{
				_sanitize_env_stream < "${workspace}/env.host"
				_sanitize_env_stream < "${workspace}/env.custom"
			} > "${workspace}/env.load"
		) || {
			log_error "Failed to write merged environment to ${workspace}/env.load"
			exit 1
		}
		env_custom="host + custom (sanitized)"
	elif [[ $use_host == true && ! -f "${workspace}/env.custom" ]]; then
		(umask 077 && sanitize_env_file "${workspace}/env.host" "${workspace}/env.load") || {
			log_error "Failed to write sanitized host environment to ${workspace}/env.load"
			exit 1
		}
		env_custom="host only (sanitized)"
	elif [[ $use_host == false && -f "${workspace}/env.custom" ]]; then
		(umask 077 && sanitize_env_file "${workspace}/env.custom" "${workspace}/env.load") || {
			log_error "Failed to write sanitized custom environment to ${workspace}/env.load"
			exit 1
		}
		env_custom="custom only (sanitized)"
	else
		env_custom="none"
	fi

	# Only add env-file if merged file exists and is not empty
	if [[ -f "${workspace}/env.load" && -s "${workspace}/env.load" ]]; then
		docker_command+=("--env-file" "${workspace}/env.load")
	fi
}

#=============================================================================
# INPUT PARSING FUNCTIONS
#=============================================================================

# Parse and validate additional docker apps
# Handle both YAML multiline (>) folded strings (space-separated) and literal (|) strings (newline-separated)
parse_app_list() {
	local input="$1"
	local -n result_array=$2

	# Clear the result array
	result_array=()

	if [[ -z $input ]]; then
		return
	fi

	# Remove carriage returns and convert newlines to spaces using built-in expansion
	local normalized_input="${input//$'\r'/}"
	normalized_input="${normalized_input//$'\n'/ }"

	# Split on whitespace to handle different YAML formats
	local -a temp_array
	read -r -a temp_array <<< "$normalized_input"

	# Filter out empty elements
	local item
	for item in "${temp_array[@]}"; do
		if [[ -n $item ]]; then
			result_array+=("$item")
		fi
	done
}

# Parse and validate docker commands
parse_docker_commands() {
	local pkg
	local e
	local e_trim
	local _flag
	local _val

	# Parse inputs
	parse_app_list "$inputs_additional_apps" inputs_additional_apps_array

	# Validate package names now that the array is populated
	for pkg in "${inputs_additional_apps_array[@]}"; do
		[[ -n $pkg ]] && validate_input "$pkg" "package_name"
	done

	# $INPUT_SETTING contains newline-separated items
	# Read lines (preserve empty lines for filtering) and strip CRs without subshell fork
	mapfile -t inputs_custom_docker_commands_array <<< "${inputs_custom_docker_commands//$'\r'/}"

	# Validate docker commands before parsing
	validate_docker_commands

	# Build a secure token array for docker run - only allow whitelisted arguments
	clean_envs=()
	for e in "${inputs_custom_docker_commands_array[@]}"; do
		# Skip empty or whitespace-only lines
		if [[ -z ${e//[[:space:]]/} ]]; then
			continue
		fi

		# Trim leading/trailing whitespace using parameter expansion
		e_trim="${e#"${e%%[![:space:]]*}"}"
		e_trim="${e_trim%"${e_trim##*[![:space:]]}"}"

		# Parse securely - only process whitelisted short and long options with a value
		if [[ $e_trim =~ ^(-[evuw]|--(env|volume|user|workdir|memory|cpus))[[:space:]]+(.+)$ ]]; then
			_flag="${BASH_REMATCH[1]}"
			_val="${BASH_REMATCH[3]}"

			# Only expand safe variable ($wd / ${wd}) when not part of a longer identifier
			if [[ $wd != *\$* ]]; then
				_val="${_val//\$\{wd\}/$wd}"
				while [[ $_val =~ ^(.*)\$wd([^A-Za-z0-9_].*|$) ]]; do
					_val="${BASH_REMATCH[1]}${wd}${BASH_REMATCH[2]}"
				done
			fi

			# Block any remaining variable expansions or command substitutions
			if [[ $_val =~ [\$\`] ]]; then
				log_error "Security: Command substitution or unsafe variable expansion blocked in: $_val"
				exit 1
			fi

			# Validate expanded value according to flag type
			case "$_flag" in
				-e | --env)
					validate_input "$_val" "env_var"
					;;
				-v | --volume)
					validate_input "$_val" "docker_volume"
					;;
				-u | --user)
					validate_input "$_val" "docker_user"
					;;
				-w | --workdir)
					validate_input "$_val" "docker_workdir"
					;;
				--memory)
					validate_input "$_val" "docker_memory"
					;;
				--cpus)
					validate_input "$_val" "docker_cpus"
					;;
			esac

			clean_envs+=("$_flag" "$_val")
		else
			log_error "Security: Invalid docker command format blocked: $e_trim"
			exit 1
		fi
	done
}

# Extract effective WORKDIR from the final build stage of a Dockerfile.
# Prints resolved absolute path if present, or empty string if the final stage sets no WORKDIR.
# Logs a warning and returns 1 if the final stage contains an invalid or path-traversing WORKDIR.
extract_dockerfile_workdir() {
	local LC_ALL=C
	local df_file="$1"
	local line
	local trimmed
	local raw_wd
	local base_ref
	local stage_wd=""
	local stage_invalid=false
	local current_stage=""
	local in_continuation=false
	local -A stage_wds=()
	local -A stage_invalids=()

	while IFS= read -r line || [[ -n $line ]]; do
		line="${line%$'\r'}"
		trimmed="${line#"${line%%[![:space:]]*}"}"

		# Comments inside backslash continuations do not terminate the continuation in Docker
		if [[ $trimmed == "#"* ]]; then
			continue
		fi

		if [[ $in_continuation == true ]]; then
			if [[ ! $trimmed =~ \\[[:space:]]*$ ]]; then
				in_continuation=false
			fi
			continue
		fi

		if [[ $trimmed =~ \\[[:space:]]*$ ]]; then
			in_continuation=true
		fi

		# Match valid Dockerfile FROM instructions: FROM [--opt=val ...] <image> [AS <name>] [# comment]
		if [[ $trimmed =~ ^[Ff][Rr][Oo][Mm][[:space:]]+(--[a-zA-Z0-9_-]+=[^[:space:]]+[[:space:]]+)*([^[:space:]#]+)([[:space:]]+[Aa][Ss][[:space:]]+([a-zA-Z0-9._-]+))?([[:space:]]*(#.*)?)?$ ]]; then
			base_ref="${BASH_REMATCH[2],,}"
			current_stage="${BASH_REMATCH[4],,}"
			stage_wd="${stage_wds[$base_ref]:-}"
			stage_invalid="${stage_invalids[$base_ref]:-false}"
			if [[ -n $current_stage ]]; then
				stage_wds["$current_stage"]="$stage_wd"
				stage_invalids["$current_stage"]="$stage_invalid"
			fi
			continue
		fi

		if [[ $trimmed =~ ^[Ww][Oo][Rr][Kk][Dd][Ii][Rr][[:space:]]+(.+)$ ]]; then
			raw_wd="${BASH_REMATCH[1]}"
			raw_wd="${raw_wd%"${raw_wd##*[![:space:]]}"}"
			if [[ $raw_wd =~ ^\"(.*)\"$ ]]; then
				raw_wd="${BASH_REMATCH[1]}"
			elif [[ $raw_wd =~ ^\'(.*)\'$ ]]; then
				raw_wd="${BASH_REMATCH[1]}"
			fi

			if [[ -z $raw_wd ]] \
				|| [[ ! $raw_wd =~ ^[a-zA-Z0-9/_.-]+$ ]] \
				|| [[ $raw_wd =~ (^|/)\.\.(/|$) ]] \
				|| [[ ${#raw_wd} -gt 256 ]]; then
				stage_invalid="$raw_wd"
				stage_wd=""
			elif [[ $raw_wd == /* ]]; then
				stage_invalid=false
				stage_wd="$raw_wd"
			elif [[ $stage_invalid == false ]]; then
				stage_wd="${stage_wd%/}/${raw_wd}"
			fi

			if [[ $stage_invalid == false ]]; then
				while [[ $stage_wd == *//* ]]; do
					stage_wd="${stage_wd//\/\//\/}"
				done
				[[ $stage_wd != "/" ]] && stage_wd="${stage_wd%/}"
				if [[ ${#stage_wd} -gt 256 ]]; then
					stage_invalid="$stage_wd"
					stage_wd=""
				fi
			fi

			if [[ -n $current_stage ]]; then
				stage_wds["$current_stage"]="$stage_wd"
				stage_invalids["$current_stage"]="$stage_invalid"
			fi
		fi
	done < "$df_file"

	if [[ $stage_invalid != false ]]; then
		log_warn "Security: Invalid WORKDIR path found in Dockerfile, using default: $stage_invalid"
		return 1
	fi

	printf '%s' "$stage_wd"
	return 0
}

#=============================================================================
# DOCKERFILE GENERATION FUNCTIONS
#=============================================================================

# Generate Dockerfile for userdocs images
generate_userdocs_dockerfile() {
	local detected_os="$1"
	local -a df_lines

	case "$detected_os" in
		"debian" | "ubuntu")
			# Use Debian/Ubuntu packages with updates/upgrades
			if [[ ${#inputs_additional_apps_array[@]} -gt 0 && -n ${inputs_additional_apps_array[0]} ]]; then
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Update packages and install additional Debian/Ubuntu packages"
					"RUN apt-get update && apt-get upgrade -y && apt-get install -y ${inputs_additional_apps_array[*]} && apt-get clean"
				)
			else
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Update and upgrade packages"
					"RUN apt-get update && apt-get upgrade -y && apt-get clean"
				)
			fi
			;;
		"alpine" | *)
			# Use Alpine packages (default/fallback) with updates/upgrades
			if [[ ${#inputs_additional_apps_array[@]} -gt 0 && -n ${inputs_additional_apps_array[0]} ]]; then
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Update packages and install additional Alpine packages"
					"RUN apk update && apk upgrade && apk add --no-cache ${inputs_additional_apps_array[*]}"
				)
			else
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Update and upgrade packages"
					"RUN apk update && apk upgrade"
				)
			fi
			;;
	esac

	printf '%s\n' "${df_lines[@]}"
}

# Generate Dockerfile for standard images
generate_standard_dockerfile() {
	local detected_os="$1"
	local backslash=$'\\'
	local -a df_lines

	case "$detected_os" in
		"alpine")
			df_lines=(
				"FROM ${inputs_os_id}:${inputs_os_version_id}"
				""
				"# Update packages, upgrade system, install packages, create group/user and configure sudo"
				"RUN apk update && apk upgrade && ${backslash}"
				"    apk add --no-cache sudo bash${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} && ${backslash}"
				"    addgroup -g ${non_root_gid} ${non_root_user} && ${backslash}"
				"    adduser -h ${wd} -D -s /bin/bash -u ${non_root_uid} -G ${non_root_user} ${non_root_user} && ${backslash}"
				"    umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && ${backslash}"
				"    chmod 0440 /etc/sudoers.d/${non_root_user}"
			)
			;;
		"debian" | "ubuntu")
			df_lines=(
				"FROM ${inputs_os_id}:${inputs_os_version_id}"
				""
				"# Locale env settings"
				"ENV LANG=C.UTF-8"
				"ENV DEBIAN_FRONTEND=noninteractive"
				"ENV TZ=Europe/London"
				""
				"# Update packages, upgrade system, install dependencies, create user/group and configure sudo"
				"RUN apt-get update && apt-get upgrade -y && ${backslash}"
				"    apt-get install -y sudo${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} && ${backslash}"
				"    groupadd -g ${non_root_gid} ${non_root_user} && ${backslash}"
				"    useradd -ms /bin/bash -u ${non_root_uid} -g ${non_root_gid} ${non_root_user} && ${backslash}"
				"    umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && ${backslash}"
				"    chmod 0440 /etc/sudoers.d/${non_root_user} && ${backslash}"
				"    apt-get clean"
			)
			;;
		"unknown" | *)
			df_lines=(
				"FROM ${inputs_os_id}:${inputs_os_version_id}"
				""
				"# Locale env settings"
				"ENV LANG=C.UTF-8"
				"ENV DEBIAN_FRONTEND=noninteractive"
				"ENV TZ=Europe/London"
				""
				"# Update packages, upgrade system, install sudo, create group/user (basic fallback) and configure sudo if present"
				"RUN if command -v apt-get >/dev/null 2>&1; then ${backslash}"
				"    apt-get update >/dev/null 2>&1 && apt-get upgrade -y >/dev/null 2>&1 && apt-get install -y sudo bash${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} >/dev/null 2>&1; ${backslash}"
				"  elif command -v apk >/dev/null 2>&1; then ${backslash}"
				"    apk update >/dev/null 2>&1 && apk upgrade >/dev/null 2>&1 && apk add --no-cache sudo bash${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} >/dev/null 2>&1; ${backslash}"
				"  fi && ${backslash}"
				"    { groupadd -g ${non_root_gid} ${non_root_user} 2>/dev/null || addgroup -g ${non_root_gid} ${non_root_user} 2>/dev/null || true; } && ${backslash}"
				"    { useradd -ms /bin/bash -u ${non_root_uid} -g ${non_root_gid} ${non_root_user} 2>/dev/null || adduser -h ${wd} -D -s /bin/bash -u ${non_root_uid} -G ${non_root_user} ${non_root_user} 2>/dev/null || true; } && ${backslash}"
				"    if command -v sudo >/dev/null 2>&1; then mkdir -p /etc/sudoers.d && umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && chmod 0440 /etc/sudoers.d/${non_root_user}; fi"
			)
			;;
	esac

	printf '%s\n' "${df_lines[@]}"
}

#=============================================================================
# GITHUB ACTIONS OUTPUT FUNCTIONS
#=============================================================================

_inputs_info() {
	printf '%b\n' '```bash'
	log_debug "=== INPUT INFO ==="
	log_debug ""
	log_debug "inputs_dockerfile=\"${inputs_dockerfile}\""
	log_debug "inputs_use_host_env=\"${inputs_use_host_env}\""
	log_debug "inputs_use_root=\"${inputs_use_root}\""
	log_debug "inputs_os_id=\"${inputs_os_id}\""
	log_debug "inputs_os_version_id=\"${inputs_os_version_id}\""
	log_debug "inputs_platform=\"${inputs_platform}\""
	log_debug "inputs_custom_docker_commands=\"$(format_clean_envs_for_log)\""
	log_debug "inputs_additional_apps=\"${inputs_additional_apps_array[*]}\""
	log_debug ""
	log_debug "=== PROCESSING CHECKS ==="
	log_debug ""

	# Show dockerfile path decision
	if [[ -n $inputs_dockerfile ]]; then
		log_debug "dockerfile_path_check=used_provided_dockerfile"
		log_debug "dockerfile_source=\"${inputs_dockerfile}\""
	else
		log_debug "dockerfile_path_check=no_dockerfile_provided"
	fi

	# Show OS detection result
	if [[ -n ${detected_os:-} ]]; then
		log_debug "os_detection_result=\"${detected_os}\""
	else
		log_debug "os_detection_result=not_performed"
	fi

	# Show platform decision
	log_debug "platform_decision=\"${inputs_platform}\""

	# Show additional apps decision
	if [[ ${#inputs_additional_apps_array[@]} -gt 0 && -n ${inputs_additional_apps_array[0]} ]]; then
		log_debug "additional_apps_check=packages_requested"
		log_debug "additional_apps_count=${#inputs_additional_apps_array[@]}"
	else
		log_debug "additional_apps_check=no_packages_requested"
	fi

	# Show custom dockerfile decision
	if [[ -n $inputs_dockerfile ]]; then
		log_debug "custom_dockerfile_needed=false"
		log_debug "custom_dockerfile_reason=user_provided_dockerfile"
	elif [[ $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		log_debug "custom_dockerfile_needed=true"
		log_debug "custom_dockerfile_reason=userdocs_with_updates"
	else
		log_debug "custom_dockerfile_needed=true"
		log_debug "custom_dockerfile_reason=standard_image_user_setup_and_updates"
	fi

	# Show environment handling
	log_debug "env_custom=\"${env_custom:-none}\""

	log_debug ""
	log_debug "=== FINAL CONFIG ==="
	log_debug ""
	log_debug "container_name=${container_name}"
	log_debug "workspace=\"${workspace}\""
	log_debug "docker_command=\"${docker_command[*]}\""
	log_debug "wd=\"${wd}\""
	log_debug ""
	log_debug "=== GITHUB OUTPUTS ==="
	log_debug ""
	log_debug "container_name=${container_name}"
	log_debug "wd=$wd"
	printf '%b\n' '```'
}

# These are set to github env/outputs and cannot be changed or manipulated by inputs
_env_info() {
	# Set environment variables using the helper function
	to_gh_env "container_name=${container_name}" || return 1
	to_gh_env "wd=$wd" || return 1

	# Set outputs using the helper function
	to_gh_output "container_name=${container_name}" || return 1
	to_gh_output "wd=$wd" || return 1
	if [[ $inputs_use_root == "true" ]]; then
		to_gh_output "uid=0" || return 1
	else
		to_gh_output "uid=${non_root_uid}" || return 1
	fi
}

to_gh_env() {
	local env_var="$1"
	# Use centralized validation without subshell fork
	if ! check_env_var "$env_var"; then
		log_error "Security: Invalid environment variable for GitHub ENV: $(redact_env_var "$env_var")"
		return 1
	fi
	if [[ -n ${GITHUB_ENV:-} ]]; then
		if [[ -L $GITHUB_ENV ]]; then
			log_error "Security: GITHUB_ENV must not be a symbolic link"
			return 1
		fi
		printf '%s\n' "$env_var" >> "$GITHUB_ENV" || return 1
	fi
	printf '%s\n' "$env_var"
}

to_gh_output() {
	local output_var="$1"
	# Use centralized validation without subshell fork
	if ! check_env_var "$output_var"; then
		log_error "Security: Invalid output variable for GitHub OUTPUT: $(redact_env_var "$output_var")"
		return 1
	fi
	if [[ -n ${GITHUB_OUTPUT:-} ]]; then
		if [[ -L $GITHUB_OUTPUT ]]; then
			log_error "Security: GITHUB_OUTPUT must not be a symbolic link"
			return 1
		fi
		printf '%s\n' "$output_var" >> "$GITHUB_OUTPUT" || return 1
	fi
	printf '%s\n' "$output_var"
}

#=============================================================================
# MAIN EXECUTION FLOW
#=============================================================================

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	readonly container_name non_root_user non_root_uid non_root_gid workspace

	# Setup platform detection and configuration first (sets defaults)
	setup_platform

	# Input validation after platform setup
	validate_basic_inputs
	validate_environment_paths

	# Parse and validate inputs before creating any files in workspace
	parse_docker_commands

	# Verify Docker CLI is available before building or running containers
	if ! command -v docker > /dev/null 2>&1; then
		log_error "Docker CLI is not installed or not in PATH"
		exit 1
	fi

	###
	### Fast-path: if the user supplied a Dockerfile, ignore other inputs except env related
	###

	if [[ -n $inputs_dockerfile ]]; then
		dockerfile_path="${workspace}/${container_name}_dockerfile"
		cleanup_dockerfile=false
		log_info "Fast-path: using provided Dockerfile: $inputs_dockerfile"

		case "$inputs_dockerfile" in
			http://* | https://* | ftp://* | git://* | ssh://* | file://*)
				log_error "Security: Remote Dockerfiles not allowed for security reasons"
				exit 1
				;;
			*)
				validate_input "$inputs_dockerfile" "dockerfile_path"
				validate_workspace_file "$inputs_dockerfile"
				ws_file_rc=$?
				if [[ $ws_file_rc -eq 1 ]]; then
					exit 1
				elif [[ $ws_file_rc -ne 0 ]]; then
					log_error "Dockerfile not found at '$workspace/$inputs_dockerfile'"
					exit 1
				fi
				if [[ ! "$workspace/$inputs_dockerfile" -ef $dockerfile_path ]]; then
					if [[ -d $dockerfile_path && ! -L $dockerfile_path ]]; then
						log_error "Failed to copy Dockerfile: destination is a directory: $dockerfile_path"
						exit 1
					fi
					rm -f "$dockerfile_path"
					cp "$workspace/$inputs_dockerfile" "$dockerfile_path" || {
						log_error "Failed to copy Dockerfile from $workspace/$inputs_dockerfile to $dockerfile_path"
						exit 1
					}
					cleanup_dockerfile=true
				fi
				;;
		esac

		if [[ ! -s $dockerfile_path ]]; then
			log_error "Dockerfile is empty or missing after fetch: $dockerfile_path"
			[[ $cleanup_dockerfile == true ]] && rm -f "$dockerfile_path"
			exit 1
		fi

		# If the Dockerfile sets WORKDIR in its final stage, resolve it and re-expand custom commands
		if extracted_wd=$(extract_dockerfile_workdir "$dockerfile_path") && [[ -n $extracted_wd ]]; then
			wd="$extracted_wd"
			if [[ -n $inputs_custom_docker_commands ]]; then
				parse_docker_commands
			fi
		fi

		# Write Dockerfile to the step summary for visibility
		if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
			log_info "Using Dockerfile: $dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			{
				printf '%b\n' '```bash'
				cat "$dockerfile_path"
				printf '%b\n' '```'
			} | tee -a "$GITHUB_STEP_SUMMARY"
		else
			log_info "Using Dockerfile: $dockerfile_path"
			cat "$dockerfile_path"
		fi

		# Build with a simple predictable tag before dumping host/custom env files into workspace
		custom_image_tag="custom_dockerfile"

		log_info "Building image from provided Dockerfile as: $custom_image_tag for platform: $inputs_platform"
		docker build --platform "$inputs_platform" -f "$dockerfile_path" -t "$custom_image_tag" "$workspace" || {
			log_error "Failed to build Docker image from provided Dockerfile"
			[[ $cleanup_dockerfile == true ]] && rm -f "$dockerfile_path"
			exit 1
		}

		# Clean up the temporary Dockerfile before starting the container
		[[ $cleanup_dockerfile == true ]] && rm -f "$dockerfile_path"

		# Process environment configuration after image build so env.host/env.load are never in build context
		process_environment

		docker_command+=("$custom_image_tag")

		# Start a container (detached) from the built image so it's running like a daemon.
		log_info "Starting container from image '$custom_image_tag' as ${container_name} (detached)"
		docker run -it -d --platform "$inputs_platform" --name "${container_name}" "${clean_envs[@]}" "${docker_command[@]}" || {
			log_error "Failed to start container from image $custom_image_tag"
			exit 1
		}

		log_debug "custom_image_tag=$custom_image_tag"

		if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
			_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
		else
			_inputs_info
		fi
		_env_info || exit 1

		exit 0
	fi

	###
	### Fast-path: ends Here
	###

	# Always create a custom Dockerfile to ensure packages are updated and upgraded
	# Check for additional packages
	if [[ ${#inputs_additional_apps_array[@]} -gt 0 && -n ${inputs_additional_apps_array[0]} ]]; then
		log_debug "Additional packages requested: ${#inputs_additional_apps_array[@]} packages"
	fi

	# Check if we have custom docker commands that require special handling
	# Most custom docker commands are runtime arguments and don't need dockerfile modification
	if [[ ${#clean_envs[@]} -gt 0 ]]; then
		log_debug "Custom Docker commands will be applied at container runtime: ${#clean_envs[@]} arguments"
	fi

	# Always create dockerfile for updates/upgrades and potential user setup
	if [[ ! $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		log_debug "Non-userdocs image requires user setup and updates"
	else
		log_debug "Userdocs image - applying updates and upgrades"
	fi

	# Create Dockerfile for package installation
	dockerfile_path="${workspace}/${container_name}_dockerfile"
	custom_image_tag="${container_name}"

	# Detect OS type for any image using centralized function
	detected_os=$(detect_image_os "${inputs_os_id}:${inputs_os_version_id}")
	log_info "Detected OS type: $detected_os for image: ${inputs_os_id}:${inputs_os_version_id}"

	# Generate Dockerfile based on image type and detected OS
	if [[ $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		log_info "Creating userdocs Dockerfile for updates and additional packages"
	else
		case "$detected_os" in
			"alpine")
				log_info "Creating Alpine Linux Dockerfile with updates"
				;;
			"debian" | "ubuntu")
				log_info "Creating Debian/Ubuntu Dockerfile with updates"
				;;
			*)
				log_info "Creating fallback Dockerfile with updates for unknown OS: $inputs_os_id"
				;;
		esac
	fi

	if [[ -d $dockerfile_path && ! -L $dockerfile_path ]]; then
		log_error "Failed to generate Dockerfile: destination is a directory: $dockerfile_path"
		exit 1
	fi
	rm -f "$dockerfile_path"
	if [[ $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		# Special handling for userdocs images - they already have user setup
		generate_userdocs_dockerfile "$detected_os" > "$dockerfile_path"
	else
		# Standard images - need full user setup
		generate_standard_dockerfile "$detected_os" > "$dockerfile_path"
	fi
	if [[ ! -s $dockerfile_path ]]; then
		log_error "Failed to generate Dockerfile at $dockerfile_path"
		rm -f "$dockerfile_path"
		exit 1
	fi
	cat "$dockerfile_path"
	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		{
			printf '%b\n' '```bash'
			cat "$dockerfile_path"
			printf '%b\n' '```'
		} >> "$GITHUB_STEP_SUMMARY"
	fi

	# Build the custom image before dumping host/custom env files into workspace
	log_info "Building container image with additional packages for platform: $inputs_platform"
	log_info "Using base image: ${inputs_os_id}:${inputs_os_version_id}"

	docker build --platform "$inputs_platform" -f "$dockerfile_path" -t "$custom_image_tag" "$workspace" || {
		log_error "Failed to build Docker image for platform $inputs_platform"
		log_error "Base image: ${inputs_os_id}:${inputs_os_version_id}"
		log_error "This could be due to: unsupported platform, missing emulation, or registry issues"
		rm -f "$dockerfile_path"
		exit 1
	}

	# Clean up the Dockerfile
	rm -f "$dockerfile_path"

	# Process environment configuration after image build so env.host/env.load are never in build context
	process_environment

	# Configure Docker security and runtime options
	if [[ $inputs_use_root == "false" ]]; then
		docker_command+=("-u" "${non_root_uid}:${non_root_gid}")
	fi

	# Security hardening: Add Docker security options.
	# --platform is passed explicitly in the docker run call; do not duplicate it here.
	docker_command+=(
		"--cap-drop" "ALL"
		"--cap-add" "CHOWN"
		"--cap-add" "DAC_OVERRIDE"
		"--cap-add" "FOWNER"
		"--cap-add" "SETUID"
		"--cap-add" "SETGID"
	)

	docker_command+=("-w" "$wd")
	docker_command+=("-v" "$workspace:$wd")
	docker_command+=("$custom_image_tag")

	docker run -it -d --platform "$inputs_platform" --name "${container_name}" "${clean_envs[@]}" "${docker_command[@]}" || {
		log_error "Failed to create Docker container with command: $(format_clean_envs_for_log) ${docker_command[*]}"
		exit 1
	}

	if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
		_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
	else
		_inputs_info
	fi
	_env_info || exit 1

fi # end sourcing guard
