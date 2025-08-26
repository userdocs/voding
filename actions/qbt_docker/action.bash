#!/bin/bash

set -euo pipefail

# Config (env-overridable)
inputs_use_host_env="${inputs_use_host_env:-false}"
inputs_use_root="${inputs_use_root:-false}"
inputs_os_id="${inputs_os_id:=alpine}"
inputs_os_version_id="${inputs_os_version_id:=edge}"
inputs_custom_docker_commands="${inputs_custom_docker_commands:-}"
inputs_additional_alpine_apps="${inputs_additional_alpine_apps:-}"
inputs_additional_debian_apps="${inputs_additional_debian_apps:-}"
inputs_dockerfile="${inputs_dockerfile:-}"
# Set default platform based on runner architecture
case "${RUNNER_ARCH:-}" in
	"X86") default_platform="linux/i386" ;;
	"X64") default_platform="linux/amd64" ;;
	"ARM") default_platform="linux/arm/v7" ;;
	"ARM64") default_platform="linux/arm64" ;;
	*) default_platform="linux/amd64" ;; # fallback to amd64
esac

inputs_platform="${inputs_platform:-$default_platform}"

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
declare dockerfile_path=""
declare custom_image_tag=""
declare env_custom=""

# Enhanced logging with levels
declare -r LOG_LEVEL="${LOG_LEVEL:-INFO}"

should_log() {
	local level=$1
	case "$LOG_LEVEL" in
		DEBUG) return 0 ;;
		INFO) [[ $level != "DEBUG" ]] ;;
		WARN) [[ $level =~ ^(WARN|ERROR)$ ]] ;;
		ERROR) [[ $level == "ERROR" ]] ;;
		*) return 1 ;;
	esac
}

# Security input validation functions
validate_input() {
	local input="$1"
	local type="$2"

	case "$type" in
		"docker_arg")
			# Only allow safe docker arguments - whitelist approach
			if [[ ! $input =~ ^(-[evuw]|--env|--volume|--user|--workdir)$ ]]; then
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
				*\;* | *\&* | *\|* | *\<* | *\>*)
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
				*\;* | *\&* | *\|* | *\<* | *\>*)
					log_error "Security: Dangerous characters in environment variable: $input"
					exit 1
					;;
			esac
			;;
		"platform")
			# Validate Docker platform format (linux/amd64, linux/arm64, etc.)
			if [[ ! $input =~ ^[a-z]+/[a-z0-9]+$ ]] || [[ ${#input} -gt 32 ]]; then
				log_error "Security: Invalid platform format blocked: $input"
				exit 1
			fi
			;;
	esac
}

# Validate Docker commands against whitelist
validate_docker_commands() {
	local -a ALLOWED_DOCKER_ARGS=("-e" "--env" "-v" "--volume" "-u" "--user" "-w" "--workdir" "--memory" "--cpus")

	for cmd_line in "${inputs_custom_docker_commands_array[@]}"; do
		[[ -z ${cmd_line//[[:space:]]/} ]] && continue

		read -ra tokens <<< "$cmd_line"
		if [[ ${#tokens[@]} -gt 0 ]]; then
			local found=false
			for allowed in "${ALLOWED_DOCKER_ARGS[@]}"; do
				if [[ ${tokens[0]} == "$allowed" ]]; then
					found=true
					break
				fi
			done
			if [[ $found == false ]]; then
				log_error "Security: Forbidden docker argument blocked: ${tokens[0]}"
				exit 1
			fi
		fi
	done
}

# Functions for consistent logging with level filtering
log_info() {
	should_log "INFO" && printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_error() {
	should_log "ERROR" && printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

log_debug() {
	should_log "DEBUG" && printf '[%s] [DEBUG] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

log_warn() {
	should_log "WARN" && printf '[%s] [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

_inputs_info() {
	printf '%b\n' "\`\`\`bash\n"
	log_debug "Input info:"
	log_debug ""
	log_debug "inputs_dockerfile=\"${inputs_dockerfile}\""
	log_debug "inputs_use_host_env=\"${inputs_use_host_env}\""
	log_debug "inputs_use_root=\"${inputs_use_root}\""
	log_debug "inputs_os_id=\"${inputs_os_id}\""
	log_debug "inputs_os_version_id=\"${inputs_os_version_id}\""
	log_debug "inputs_custom_docker_commands=\"${clean_envs[*]}\""
	log_debug "inputs_additional_alpine_apps=\"${inputs_additional_alpine_apps_array[*]}\""
	log_debug "inputs_additional_debian_apps=\"${inputs_additional_debian_apps_array[*]}\""
	log_debug ""
	log_debug "other info:"
	log_debug ""
	log_debug "env_custom=\"${env_custom:-none}\""
	log_debug "container_name=${container_name}"
	log_debug "workspace=\"${workspace}\""
	log_debug "docker_command=\"${docker_command[*]}\""
	log_debug "wd=\"${wd}\""
	log_debug ""
	log_debug "env/output info: These are set to github env/outputs and cannot be changed or manipulated by inputs"
	log_debug ""
	log_debug "container_name=${container_name}"
	log_debug "wd=$wd"
	printf '%b\n' '```'
}

# These are set to github env/outputs and cannot be changed or manipulated by inputs"

_env_info() {
	printf '%s\n' "container_name=${container_name}" >> "$GITHUB_ENV"
	printf '%s\n' "wd=$wd" >> "$GITHUB_ENV"
}

to_gh_env() {
	printf '%s\n' "${1}" | tee -a "$GITHUB_ENV"
}

to_gh_output() {
	printf '%s\n' "${1}" | tee -a "$GITHUB_OUTPUT"
}

log_summary() {
	printf '%b\n' '```bash' | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' "${1}" | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' '```' | tee -a "$GITHUB_STEP_SUMMARY"
}

# Sanitize environment files
sanitize_env_file() {
	local input_file="$1"
	local output_file="$2"

	if [[ -f $input_file ]]; then
		# Filter valid env vars and block dangerous ones
		while IFS= read -r line; do
			[[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
			# Validate env var format and block dangerous variables
			if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] && [[ ! $line =~ ^(PATH|LD_|BASH_|SHELL|HOME)= ]]; then
				# Check for dangerous characters using case
				case "$line" in
					*\;* | *\&* | *\|* | *\<* | *\>*)
						log_error "Security: Dangerous characters in environment variable: $line"
						;;
					*)
						echo "$line"
						;;
				esac
			else
				log_error "Security: Invalid environment variable blocked: $line"
			fi
		done < "$input_file" > "$output_file"
	fi
}

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

# Note: The yml coming through from the action with is new line separated not space separated

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

parse_app_list "$inputs_additional_alpine_apps" inputs_additional_alpine_apps_array
parse_app_list "$inputs_additional_debian_apps" inputs_additional_debian_apps_array

# Validate platform input for security
validate_input "$inputs_platform" "platform"

# Validate package names for security
for pkg in "${inputs_additional_alpine_apps_array[@]}"; do
	[[ -n $pkg ]] && validate_input "$pkg" "package_name"
done
for pkg in "${inputs_additional_debian_apps_array[@]}"; do
	[[ -n $pkg ]] && validate_input "$pkg" "package_name"
done

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
		# Additional security: prevent command substitution
		if [[ $_val =~ \$\(|\`|\$\{[^wd] ]]; then
			log_error "Security: Command substitution blocked in: $_val"
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
		if [[ $_val =~ \$\(|\`|\$\{[^wd] ]]; then
			log_error "Security: Command substitution blocked in: $_val"
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
		if [[ $_t =~ \$\(|\`|\$\{[^wd] ]]; then
			log_error "Security: Command substitution blocked in: $_t"
			exit 1
		fi
		clean_envs+=("$_t")
	done
done

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

	log_info "Building image from provided Dockerfile as: $custom_image_tag"
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
	wd="$(sed -rn 's/WORKDIR (.*)/\1/p' "$dockerfile_path")"

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

if [[ $inputs_use_root == "false" ]]; then
	docker_command+=("-u" "${non_root_uid}:${non_root_gid}")
fi

# Security hardening: Add Docker security options
docker_command+=(
	"--platform" "$inputs_platform"
	"--security-opt" "no-new-privileges:true"
	"--cap-drop" "ALL"
	"--cap-add" "CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID"
	"--memory" "2g"
	"--cpus" "2.0"
	"--pids-limit" "1024"
	"--ulimit" "nofile=65536:65536"
)

docker_command+=("-w" "$wd")
docker_command+=("-v" "$workspace:$wd")

# Check if we need to create a custom Dockerfile for additional packages
need_custom_dockerfile=false
if [[ ${#inputs_additional_alpine_apps_array[@]} -gt 0 && ${inputs_additional_alpine_apps_array[0]} != "" ]]; then
	need_custom_dockerfile=true
fi
if [[ ${#inputs_additional_debian_apps_array[@]} -gt 0 && ${inputs_additional_debian_apps_array[0]} != "" ]]; then
	need_custom_dockerfile=true
fi

if [[ $need_custom_dockerfile == true ]]; then
	# Create Dockerfile for package installation
	dockerfile_path="${workspace}/${container_name}_dockerfile"
	custom_image_tag="${container_name}"

	# Avoid heredoc (EOF) which can break in some CI environments (GitHub Actions).
	case "$inputs_os_id" in
		ghcr.io/userdocs/*)
			log_info "Creating userdocs Dockerfile for additional packages"
			printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
			{
				# Determine package manager based on image name
				if [[ $inputs_os_id =~ alpine ]]; then
					df_lines=(
						"FROM ${inputs_os_id}:${inputs_os_version_id}"
						""
						"# Install additional Alpine packages"
						"RUN apk add --no-cache ${inputs_additional_alpine_apps_array[@]}"
					)
				else
					# Assume Debian/Ubuntu based userdocs image
					df_lines=(
						"FROM ${inputs_os_id}:${inputs_os_version_id}"
						""
						"# Install additional Debian/Ubuntu packages"
						"RUN apt-get update && apt-get install -y ${inputs_additional_debian_apps_array[@]} && apt-get clean"
					)
				fi
				printf '%s\n' "${df_lines[@]}"
			} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"
			;;
		alpine | */alpine)
			log_info "Creating Alpine Linux Dockerfile"
			printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
			{
				backslash=$'\\'
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Install packages, create group/user and configure sudo"
					"RUN apk add --no-cache sudo bash ${inputs_additional_alpine_apps_array[@]} && ${backslash}"
					"    addgroup -g ${non_root_gid} ${non_root_user} && ${backslash}"
					"    adduser -h ${wd} -D -s /bin/bash -u ${non_root_uid} -G ${non_root_user} ${non_root_user} && ${backslash}"
					"    umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && ${backslash}"
					"    chmod 0440 /etc/sudoers.d/${non_root_user}"
				)
				printf '%s\n' "${df_lines[@]}"
			} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"
			;;
		debian | */debian | ubuntu | */ubuntu)
			log_info "Creating Debian/Ubuntu Dockerfile"
			printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
			{
				backslash=$'\\'
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Locale env settings"
					"ENV LANG=C.UTF-8"
					"ENV DEBIAN_FRONTEND=noninteractive"
					"ENV TZ=Europe/London"
					""
					"# Update packages, install dependencies, create user/group and configure sudo"
					"RUN apt-get update && apt-get upgrade -y && ${backslash}"
					"    apt-get install -y sudo ${inputs_additional_debian_apps_array[@]} && ${backslash}"
					"    groupadd -g ${non_root_gid} ${non_root_user} && ${backslash}"
					"    useradd -ms /bin/bash -u ${non_root_uid} -g ${non_root_gid} ${non_root_user} && ${backslash}"
					"    umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && ${backslash}"
					"    chmod 0440 /etc/sudoers.d/${non_root_user}"
				)
				printf '%s\n' "${df_lines[@]}"
			} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"
			;;
		*)
			log_info "Creating basic Dockerfile for unsupported OS: $inputs_os_id"
			printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
			{
				backslash=$'\\'
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Locale env settings"
					"ENV LANG=C.UTF-8"
					"ENV DEBIAN_FRONTEND=noninteractive"
					"ENV TZ=Europe/London"
					""
					"# Try to install sudo, create group/user (basic fallback) and configure sudo if present"
					"RUN if command -v apt-get >/dev/null 2>&1; then ${backslash}"
					"    apt-get update >/dev/null 2>&1 && apt-get install -y sudo ${inputs_additional_debian_apps_array[@]} >/dev/null 2>&1; ${backslash}"
					"  elif command -v apk >/dev/null 2>&1; then ${backslash}"
					"    apk add --no-cache sudo ${inputs_additional_alpine_apps_array[@]} >/dev/null 2>&1; ${backslash}"
					"  fi && ${backslash}"
					"    groupadd -g ${non_root_gid} ${non_root_user} 2>/dev/null || addgroup ${non_root_gid} 2>/dev/null || true && ${backslash}"
					"    useradd -ms /bin/bash -u ${non_root_uid} ${non_root_user} 2>/dev/null || adduser -h ${wd} -D -s /bin/bash -u ${non_root_uid} ${non_root_user} 2>/dev/null || true && ${backslash}"
					"    if command -v sudo >/dev/null 2>&1; then umask 077 && printf '%s\\n' \"${non_root_user} ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/${non_root_user} && chmod 0440 /etc/sudoers.d/${non_root_user}; fi"
				)
				printf '%s\n' "${df_lines[@]}"
			} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"
			;;
	esac

	# Build the custom image
	log_info "Building container image with additional packages"
	docker build --platform "$inputs_platform" -f "$dockerfile_path" -t "$custom_image_tag" . || {
		log_error "Failed to build Docker image"
		exit 1
	}

	# Clean up the Dockerfile
	rm -f "$dockerfile_path"

	docker_command+=("$custom_image_tag")
else
	# Use original image without modifications
	docker_command+=("${inputs_os_id}:${inputs_os_version_id}")
fi

docker run -it -d --name "${container_name}" "${clean_envs[@]}" "${docker_command[@]}" || {
	log_error "Failed to create Docker container with command: ${docker_command[*]}"
	exit 1
}

_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
_env_info
