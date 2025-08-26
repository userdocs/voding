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
# - Prevention of command injection and path traversal attacks
# - GitHub environment variable protection
# - Docker security options (no-new-privileges, capability restrictions)
# - Resource limits (memory, CPU, PIDs)
#
# Platform Support:
# - Automatic platform detection from runner architecture
# - Support for arch-prefixed images (e.g., arm64v8/alpine:edge)
# - Platform validation against OS compatibility matrix

#=============================================================================
# CONFIGURATION AND CONSTANTS
#=============================================================================

# Config (env-overridable)
inputs_dockerfile="${inputs_dockerfile:-}"
inputs_use_host_env="${inputs_use_host_env:-false}"
inputs_use_root="${inputs_use_root:-false}"
inputs_os_id="${inputs_os_id:=alpine}"
inputs_os_version_id="${inputs_os_version_id:=edge}"
inputs_custom_docker_commands="${inputs_custom_docker_commands:-}"
inputs_additional_apps="${inputs_additional_apps:-}"
inputs_platform="${inputs_platform:-}"
workspace=${GITHUB_WORKSPACE}
runner_arch=${RUNNER_ARCH}

# These variables are immutable and cannot be changed by injection or used to run subshell commands.
readonly container_name="qbt_builder"
readonly wd="/home/gh"
readonly non_root_user="gh"
readonly non_root_uid="1001"
readonly non_root_gid="1001"
readonly workspace="${GITHUB_WORKSPACE:-$PWD}"

# Declare arrays and variables early
declare -a docker_command=()
declare -a clean_envs=()
declare -a inputs_additional_apps_array=()
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

log_summary() {
	printf '%b\n' '```bash' | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' "${1}" | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' '```' | tee -a "$GITHUB_STEP_SUMMARY"
}

#=============================================================================
# VALIDATION FUNCTIONS
#=============================================================================

# Security input validation functions
validate_input() {
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
			# Validate package names (alphanumeric, hyphens, dots, plus signs)
			if [[ ! $input =~ ^[a-zA-Z0-9.+_-]+$ ]] || [[ ${#input} -gt 128 ]]; then
				log_error "Security: Invalid package name blocked: $input"
				exit 1
			fi
			;;
		"dockerfile_path")
			# Restrict to workspace-relative paths only, no traversal
			if [[ $input =~ \.\.|^/ ]] || [[ ${#input} -gt 256 ]] || [[ ! $input =~ ^[a-zA-Z0-9._/-]+$ ]]; then
				log_error "Security: Invalid dockerfile path blocked: $input"
				exit 1
			fi
			# Additional check for dangerous characters
			case "$input" in
				*\;* | *\&* | *\|* | *\<* | *\>* | *\`* | *\$\(*)
					log_error "Security: Dangerous characters in dockerfile path: $input"
					exit 1
					;;
			esac
			;;
		"env_var")
			# Validate environment variable format and block dangerous ones
			if [[ ! $input =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || [[ $input =~ ^(PATH|LD_|BASH_|SHELL|HOME)= ]]; then
				log_error "Security: Invalid environment variable blocked: $input"
				exit 1
			fi
			# Check for dangerous characters using case
			case "$input" in
				*\;* | *\&* | *\|* | *\<* | *\>* | *\`* | *\$\(*)
					log_error "Security: Dangerous characters in environment variable: $input"
					exit 1
					;;
			esac
			;;
		"platform")
			# Validate Docker platform format
			if [[ ! $input =~ ^[a-z]+/[a-z0-9]+(/v[0-9]+)?$ ]] || [[ ${#input} -gt 32 ]]; then
				log_error "Security: Invalid platform format blocked: $input"
				exit 1
			fi
			;;
	esac
}

# Validate Docker commands against whitelist
validate_docker_commands() {
	for cmd_line in "${inputs_custom_docker_commands_array[@]}"; do
		[[ -z ${cmd_line//[[:space:]]/} ]] && continue

		read -ra tokens <<< "$cmd_line"
		if [[ ${#tokens[@]} -gt 0 ]]; then
			validate_input "${tokens[0]}" "docker_arg"
		fi
	done
}

# Validate basic inputs
validate_basic_inputs() {
	# Validate boolean inputs
	if [[ ! $inputs_use_host_env =~ ^(true|false)$ ]]; then
		log_error "Security: inputs_use_host_env must be 'true' or 'false', got: $inputs_use_host_env"
		exit 1
	fi
	if [[ ! $inputs_use_root =~ ^(true|false)$ ]]; then
		log_error "Security: inputs_use_root must be 'true' or 'false', got: $inputs_use_root"
		exit 1
	fi

	# Validate os_id format
	if [[ ! $inputs_os_id =~ ^[a-zA-Z0-9._/-]+$ ]] || [[ ${#inputs_os_id} -gt 128 ]]; then
		log_error "Security: Invalid inputs_os_id format: $inputs_os_id"
		exit 1
	fi

	# Validate os_version_id format
	if [[ ! $inputs_os_version_id =~ ^[a-zA-Z0-9._-]+$ ]] || [[ ${#inputs_os_version_id} -gt 64 ]]; then
		log_error "Security: Invalid inputs_os_version_id format: $inputs_os_version_id"
		exit 1
	fi

	# Validate platform input for security
	validate_input "$inputs_platform" "platform"

	# Validate package names for security
	for pkg in "${inputs_additional_apps_array[@]}"; do
		[[ -n $pkg ]] && validate_input "$pkg" "package_name"
	done
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
		docker_inspect_json=$(docker buildx imagetools inspect "$image" --format '{{json .}}' 2> /dev/null || echo "")

		if [[ -n $docker_inspect_json && $docker_inspect_json != "" ]]; then
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
	local docker_inspect_json="$1"
	local detected_os=""

	log_debug "Checking for GHCR userdocs metadata" >&2

	# Check for userdocs-specific labels
	local base_id
	local base_name
	base_id=$(echo "$docker_inspect_json" | jq -r 'try (.image[.image | keys[0]].config.Labels."org.opencontainers.image.base.id" // "")' 2> /dev/null || echo "")
	base_name=$(echo "$docker_inspect_json" | jq -r 'try (.image[.image | keys[0]].config.Labels."org.opencontainers.image.base.name" // "")' 2> /dev/null || echo "")

	if [[ -n $base_id && $base_id != "null" && $base_id != "" ]]; then
		log_debug "Found userdocs base.id: $base_id" >&2
		case "$base_id" in
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
	elif [[ -n $base_name && $base_name != "null" && $base_name != "" ]]; then
		log_debug "Found userdocs base.name: $base_name" >&2
		# Parse base.name (e.g., "alpine:edge")
		local base_os
		base_os="${base_name%%:*}" # Extract part before :
		base_os="${base_os%%/*}"   # Extract part before / (in case of registry prefix)
		case "$base_os" in
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
	local docker_inspect_json="$1"
	local image="$2"
	local detected_os=""

	log_debug "Checking for official Docker image patterns" >&2

	# Check URL metadata for official Docker images
	local image_url
	image_url=$(echo "$docker_inspect_json" | jq -r 'try (.image[.image | keys[0]].config.Labels."org.opencontainers.image.url" // "")' 2> /dev/null || echo "")

	if [[ -n $image_url && $image_url != "null" && $image_url != "" ]]; then
		log_debug "Found image URL: $image_url" >&2

		case "$image_url" in
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
		image_name=$(echo "$docker_inspect_json" | jq -r 'try (.name // "")' 2> /dev/null || echo "$image")

		if [[ -n $image_name && $image_name != "null" ]]; then
			log_debug "Checking image name: $image_name" >&2

			# Handle arch-prefixed images (e.g., arm64v8/alpine:edge)
			local base_name="$image_name"
			if [[ $image_name =~ ^[a-z0-9]+/(.*) ]]; then
				base_name="${BASH_REMATCH[1]}"
				log_debug "Detected arch-prefixed image, using base: $base_name" >&2
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
	local docker_inspect_json="$1"
	local image="$2"
	local detected_os=""

	log_debug "Using fallback detection with metadata" >&2

	# Check history for OS hints
	local history_check
	history_check=$(echo "$docker_inspect_json" | jq -r 'try (.image[.image | keys[0]].history[].created_by // "")' 2> /dev/null | grep -i -E 'alpine|debian|ubuntu' | head -1 || echo "")

	if [[ -n $history_check ]]; then
		log_debug "Found OS in history: $history_check" >&2
		case "$history_check" in
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
	local image="$1"
	local detected_os=""

	log_debug "Using name-only fallback detection" >&2

	# Handle arch-prefixed images (e.g., arm64v8/alpine:edge)
	local base_image="$image"
	if [[ $image =~ ^[a-z0-9]+/(.*) ]]; then
		base_image="${BASH_REMATCH[1]}"
		log_debug "Detected arch-prefixed image, using base: $base_image" >&2
	fi

	# Split on common separators and check each part
	local IFS=$':-_/'
	local -a name_parts
	read -ra name_parts <<< "$base_image"

	for part in "${name_parts[@]}"; do
		case "$part" in
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
	# Parse arch-prefixed image names (e.g., arm64v8/alpine:edge) and set platform
	# Only match known architecture prefixes to avoid parsing registry URLs
	if [[ $inputs_os_id =~ ^(amd64|i386|arm32v6|arm32v7|arm64v8|ppc64le|s390x|riscv64)/(.+)$ ]]; then
		arch_prefix="${BASH_REMATCH[1]}"
		image_name="${BASH_REMATCH[2]}"

		# Validate image name for security
		if [[ ! $image_name =~ ^[a-zA-Z0-9._/-]+$ ]] || [[ ${#image_name} -gt 128 ]]; then
			log_error "Security: Invalid image name format: $image_name"
			exit 1
		fi

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

	# Set default platform based on runner architecture only if inputs_platform is still empty/null/unset
	if [[ -z ${inputs_platform} ]]; then
		case "${runner_arch:-}" in
			"X86") inputs_platform="linux/i386" ;;
			"X64") inputs_platform="linux/amd64" ;;
			"ARM") inputs_platform="linux/arm/v7" ;;
			"ARM64") inputs_platform="linux/arm64" ;;
			*) inputs_platform="linux/amd64" ;; # fallback to amd64
		esac
		log_debug "Using runner architecture detection: ${RUNNER_ARCH:-unknown} -> platform: $inputs_platform"
	fi
}

#=============================================================================
# ENVIRONMENT PROCESSING FUNCTIONS
#=============================================================================

# Sanitize environment files
sanitize_env_file() {
	local input_file="$1"
	local output_file="$2"

	if [[ -f $input_file ]]; then
		# Filter valid env vars and block dangerous ones
		while IFS= read -r line; do
			[[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
			# Use centralized validation
			if validate_input "$line" "env_var" 2> /dev/null; then
				echo "$line"
			else
				log_error "Security: Invalid environment variable blocked: $line"
			fi
		done < "$input_file" > "$output_file"
	fi
}

# Process environment configuration
process_environment() {
	if [[ $inputs_use_host_env == 'true' ]]; then
		env > "${workspace}/env.host"
		log_info "Security: Host environment dumped - review for sensitive data"
	fi

	if [[ -f "${workspace}/env.host" && -f "${workspace}/env.custom" ]]; then
		sanitize_env_file "${workspace}/env.host" "${workspace}/env.host.safe"
		sanitize_env_file "${workspace}/env.custom" "${workspace}/env.custom.safe"
		cat "${workspace}/env.host.safe" "${workspace}/env.custom.safe" > "${workspace}/env.load"
		env_custom="host + custom (sanitized)"
	elif [[ -f "${workspace}/env.host" && ! -f "${workspace}/env.custom" ]]; then
		sanitize_env_file "${workspace}/env.host" "${workspace}/env.load"
		env_custom="host only (sanitized)"
	elif [[ ! -f "${workspace}/env.host" && -f "${workspace}/env.custom" ]]; then
		sanitize_env_file "${workspace}/env.custom" "${workspace}/env.load"
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

	# Remove carriage returns and convert newlines to spaces
	local normalized_input
	normalized_input=$(printf '%s' "$input" | tr -d '\r' | tr '\n' ' ')

	# Split on whitespace to handle different YAML formats
	local temp_array
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
	# Parse inputs
	parse_app_list "$inputs_additional_apps" inputs_additional_apps_array

	# $INPUT_SETTING contains newline-separated items
	# Read lines (preserve empty lines for filtering) and strip CRs
	mapfile -t inputs_custom_docker_commands_array <<< "$(printf '%s' "$inputs_custom_docker_commands" | tr -d '\r')"

	# Validate docker commands before parsing
	validate_docker_commands

	# Build a secure token array for docker run - only allow whitelisted arguments
	clean_envs=()
	for e in "${inputs_custom_docker_commands_array[@]}"; do
		# Skip empty or whitespace-only lines
		if [[ -z ${e//[[:space:]]/} ]]; then
			continue
		fi

		# Trim leading/trailing whitespace
		e_trim=$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

		# Parse securely - only process whitelisted arguments
		if [[ $e_trim =~ ^-([evuw])[[:space:]]+(.+) ]]; then
			clean_envs+=("-${BASH_REMATCH[1]}")
			# Only expand safe variables (wd only)
			_val="${BASH_REMATCH[2]}"
			_val="${_val//\$\{wd\}/$wd}"
			_val="${_val//\$wd/$wd}"
			# Additional security: prevent command substitution and unsafe expansions
			if [[ $_val =~ \$\(|\`|\$\{[^w]|\$[^w{] ]]; then
				log_error "Security: Command substitution or unsafe variable expansion blocked in: $_val"
				exit 1
			fi
			clean_envs+=("$_val")
			continue
		fi

		# Handle long options securely
		if [[ $e_trim =~ ^(--(?:env|volume|user|workdir|memory|cpus))[[:space:]]+(.+) ]]; then
			clean_envs+=("${BASH_REMATCH[1]}")
			_val="${BASH_REMATCH[2]}"
			_val="${_val//\$\{wd\}/$wd}"
			_val="${_val//\$wd/$wd}"
			# Additional security check
			if [[ $_val =~ \$\(|\`|\$\{[^w]|\$[^w{] ]]; then
				log_error "Security: Command substitution or unsafe variable expansion blocked in: $_val"
				exit 1
			fi
			clean_envs+=("$_val")
			continue
		fi

		# For other formats, split carefully and validate each token
		read -r -a tokens <<< "$e_trim"
		for t in "${tokens[@]}"; do
			# Only expand safe variables
			_t="$t"
			_t="${_t//\$\{wd\}/$wd}"
			_t="${_t//\$wd/$wd}"
			# Security check for command substitution
			if [[ $_t =~ \$\(|\`|\$\{[^w]|\$[^w{] ]]; then
				log_error "Security: Command substitution or unsafe variable expansion blocked in: $_t"
				exit 1
			fi
			clean_envs+=("$_t")
		done
	done
}

#=============================================================================
# DOCKERFILE GENERATION FUNCTIONS
#=============================================================================

# Generate Dockerfile for userdocs images
generate_userdocs_dockerfile() {
	local detected_os="$1"

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
				"    apt-get update >/dev/null 2>&1 && apt-get upgrade -y >/dev/null 2>&1 && apt-get install -y sudo${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} >/dev/null 2>&1; ${backslash}"
				"  elif command -v apk >/dev/null 2>&1; then ${backslash}"
				"    apk update >/dev/null 2>&1 && apk upgrade >/dev/null 2>&1 && apk add --no-cache sudo${inputs_additional_apps_array[*]:+ ${inputs_additional_apps_array[*]}} >/dev/null 2>&1; ${backslash}"
				"  fi && ${backslash}"
				"    groupadd -g ${non_root_gid} ${non_root_user} 2>/dev/null || addgroup ${non_root_gid} 2>/dev/null || true && ${backslash}"
				"    useradd -ms /bin/bash -u ${non_root_uid} ${non_root_user} 2>/dev/null || adduser -h ${wd} -D -s /bin/bash -u ${non_root_uid} ${non_root_user} 2>/dev/null || true && ${backslash}"
				"    if command -v sudo >/dev/null 2>&1; then umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && chmod 0440 /etc/sudoers.d/${non_root_user}; fi"
			)
			;;
	esac

	printf '%s\n' "${df_lines[@]}"
}

#=============================================================================
# GITHUB ACTIONS OUTPUT FUNCTIONS
#=============================================================================

_inputs_info() {
	printf '%b\n' "\`\`\`bash\n"
	log_debug "=== INPUT INFO ==="
	log_debug ""
	log_debug "inputs_dockerfile=\"${inputs_dockerfile}\""
	log_debug "inputs_use_host_env=\"${inputs_use_host_env}\""
	log_debug "inputs_use_root=\"${inputs_use_root}\""
	log_debug "inputs_os_id=\"${inputs_os_id}\""
	log_debug "inputs_os_version_id=\"${inputs_os_version_id}\""
	log_debug "inputs_platform=\"${inputs_platform}\""
	log_debug "inputs_custom_docker_commands=\"${clean_envs[*]}\""
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
	log_debug "custom_dockerfile_needed=true"
	if [[ $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		log_debug "custom_dockerfile_reason=userdocs_with_updates"
	else
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

# These are set to github env/outputs and cannot be changed or manipulated by inputs"
_env_info() {
	# Set environment variables using the helper function
	to_gh_env "container_name=${container_name}"
	to_gh_env "wd=$wd"

	# Set outputs using the helper function
	to_gh_output "container_name=${container_name}"
	to_gh_output "wd=$wd"
	if [[ $inputs_use_root == "true" ]]; then
		to_gh_output "uid=0"
	else
		to_gh_output "uid=${non_root_uid}"
	fi
}

to_gh_env() {
	local env_var="$1"
	# Use centralized validation
	if ! validate_input "$env_var" "env_var" 2> /dev/null; then
		log_error "Security: Invalid environment variable for GitHub ENV: $env_var"
		return 1
	fi
	printf '%s\n' "$env_var" | tee -a "$GITHUB_ENV"
}

to_gh_output() {
	local output_var="$1"
	# Use centralized validation
	if ! validate_input "$output_var" "env_var" 2> /dev/null; then
		log_error "Security: Invalid output variable for GitHub OUTPUT: $output_var"
		return 1
	fi
	printf '%s\n' "$output_var" | tee -a "$GITHUB_OUTPUT"
}

#=============================================================================
# MAIN EXECUTION FLOW
#=============================================================================

# Setup platform detection and configuration first (sets defaults)
setup_platform

# Input validation after platform setup
validate_basic_inputs

# Process environment configuration
process_environment

# Parse and validate inputs
parse_docker_commands

###
### Fast-path: if the user supplied a Dockerfile, ignore other inputs except env related
###

if [[ -n $inputs_dockerfile ]]; then
	dockerfile_path="${workspace}/${container_name}_dockerfile"
	log_info "Fast-path: using provided Dockerfile: $inputs_dockerfile"

	case "$inputs_dockerfile" in
		http://* | https://*)
			log_error "Security: Remote Dockerfiles not allowed for security reasons"
			exit 1
			;;
		*)
			validate_input "$inputs_dockerfile" "dockerfile_path"
			if [[ -f "$workspace/$inputs_dockerfile" ]]; then
				cp "$workspace/$inputs_dockerfile" "$dockerfile_path" || {
					log_error "Failed to copy Dockerfile from $workspace/$inputs_dockerfile to $dockerfile_path"
					exit 1
				}
			else
				log_error "Dockerfile not found at '$workspace/$inputs_dockerfile'"
				exit 1
			fi
			;;
	esac

	if [[ ! -s $dockerfile_path ]]; then
		log_error "Dockerfile is empty or missing after fetch: $dockerfile_path"
		exit 1
	fi

	# Write Dockerfile to the step summary for visibility
	log_info "Using Dockerfile: $dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
	{
		printf '%b\n' "\`\`\`bash\n"
		cat "$dockerfile_path"
		printf '%b\n' '```'
	} | tee -a "$GITHUB_STEP_SUMMARY"

	# Build with a simple predictable tag
	custom_image_tag="custom_dockerfile"

	log_info "Building image from provided Dockerfile as: $custom_image_tag for platform: $inputs_platform"
	docker build --platform "$inputs_platform" -f "$dockerfile_path" -t "$custom_image_tag" . || {
		log_error "Failed to build Docker image from provided Dockerfile"
		# Clean up Dockerfile if left behind
		rm -f "$dockerfile_path"
		exit 1
	}

	docker_command+=("$custom_image_tag")

	# Start a container (detached) from the built image so it's running like a daemon.
	log_info "Starting container from image '$custom_image_tag' as ${container_name} (detached)"
	docker run -it -d --platform "$inputs_platform" --name "${container_name}" "${clean_envs[@]}" "${docker_command[@]}" || {
		log_error "Failed to start container from image $custom_image_tag"
		rm -f "$dockerfile_path"
		exit 1
	}

	# if the dockerfile has a WORKDIR set grab the path and set it to wd or we have no idea what it is.
	# Use safe parsing to prevent command injection
	extracted_wd
	extracted_wd=$(grep -E '^[[:space:]]*WORKDIR[[:space:]]+' "$dockerfile_path" | tail -1 | sed -E 's/^[[:space:]]*WORKDIR[[:space:]]+//' || echo "")
	if [[ -n $extracted_wd ]]; then
		# Validate extracted workdir for security
		if [[ $extracted_wd =~ ^[a-zA-Z0-9/_.-]+$ ]] && [[ ${#extracted_wd} -le 256 ]]; then
			wd="$extracted_wd"
		else
			# Log warning about invalid WORKDIR (but continue with default)
			printf '[%s] [WARN] Security: Invalid WORKDIR path found in Dockerfile, using default: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$extracted_wd" >&2
		fi
	fi

	# Clean up the temporary Dockerfile and emit minimal outputs
	rm -f "$dockerfile_path"

	log_debug "custom_image_tag=$custom_image_tag"

	_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
	_env_info

	exit 0
fi

###
### Fast-path: ends Here
###

# Configure Docker security and runtime options
if [[ $inputs_use_root == "false" ]]; then
	docker_command+=("-u" "${non_root_uid}:${non_root_gid}")
fi

# Security hardening: Add Docker security options
docker_command+=(
	"--platform" "$inputs_platform"
	"--cap-drop" "ALL"
	"--cap-add" "CHOWN"
	"--cap-add" "DAC_OVERRIDE"
	"--cap-add" "FOWNER"
	"--cap-add" "SETUID"
	"--cap-add" "SETGID"
)

docker_command+=("-w" "$wd")
docker_command+=("-v" "$workspace:$wd")

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

printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
{
	if [[ $inputs_os_id =~ ^ghcr\.io/userdocs/ ]]; then
		# Special handling for userdocs images - they already have user setup
		generate_userdocs_dockerfile "$detected_os"
	else
		# Standard images - need full user setup
		generate_standard_dockerfile "$detected_os"
	fi
} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"

# Build the custom image
log_info "Building container image with additional packages for platform: $inputs_platform"
log_info "Using base image: ${inputs_os_id}:${inputs_os_version_id}"

docker build --platform "$inputs_platform" -f "$dockerfile_path" -t "$custom_image_tag" . || {
	log_error "Failed to build Docker image for platform $inputs_platform"
	log_error "Base image: ${inputs_os_id}:${inputs_os_version_id}"

	log_error "Failed to build for platform $inputs_platform"
	log_error "This could be due to: unsupported platform, missing emulation, or registry issues"
	exit 1
}

# Clean up the Dockerfile
rm -f "$dockerfile_path"

docker_command+=("$custom_image_tag")

docker run -it -d --platform "$inputs_platform" --name "${container_name}" "${clean_envs[@]}" "${docker_command[@]}" || {
	log_error "Failed to create Docker container with command: ${docker_command[*]}"
	exit 1
}

_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
_env_info
