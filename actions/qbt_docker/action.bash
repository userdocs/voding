#!/bin/bash

# Config (env-overridable)
inputs_use_host_env="${inputs_use_host_env:-false}"
inputs_use_root="${inputs_use_root:-false}"
inputs_os_id="${inputs_os_id:=alpine}"
inputs_os_version_id="${inputs_os_version_id:=edge}"
inputs_custom_docker_commands="${inputs_custom_docker_commands:-}"
inputs_additional_alpine_apps="${inputs_additional_alpine_apps:-}"
inputs_additional_debian_apps="${inputs_additional_debian_apps:-}"
inputs_dockerfile="${inputs_dockerfile:-}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

# Functions for consistent logging
log_info() {
	printf '[INFO] %s\n' "$1"
}

log_error() {
	printf '[ERROR] %s\n' "$1" >&2
}

log_debug() {
	printf '[DEBUG] %s\n' "$1"
}

# Set the vars for log summaries.
if [[ $inputs_use_root == "true" ]]; then
	username="root"
	username_uid="0"
	username_gid="0"
else
	username="gh"
	username_uid="1001"
	username_gid="1001"
fi

_inputs_info() {
	printf '%b\n' "\`\`\`bash\n"
	log_debug "Input info:"
	log_debug "inputs_dockerfile=\"${inputs_dockerfile}\""
	log_debug "inputs_use_host_env=\"${inputs_use_host_env}\""
	log_debug "env_custom=\"${env_custom:-none}\""
	log_debug "inputs_use_root=\"${inputs_use_root}\""
	log_debug 'container_name="qbt_builder"'
	log_debug "inputs_os_id=\"${inputs_os_id}\""
	log_debug "inputs_os_version_id=\"${inputs_os_version_id}\""
	log_debug "inputs_custom_docker_commands=\"${inputs_custom_docker_commands}\""
	log_debug "inputs_additional_debian_apps=\"${inputs_additional_debian_apps}\""
	log_debug "inputs_additional_alpine_apps=\"${inputs_additional_alpine_apps}\""
	log_debug "workspace=\"${workspace}\""
	log_debug "docker_command=\"${docker_command[*]}\""
	log_debug "wd=\"${wd}\""

	log_debug "env/output info: These are set to github env/outputs and cannot be changed or manipulated by inputs"

	log_debug "container_name=qbt_builder"
	log_debug "username=$username"
	log_debug "username_uid=$username_uid"
	log_debug "username_gid=$username_gid"
	log_debug "wd=$wd"
	printf '%b\n' '```'
}

# These are set to github env/outputs and cannot be changed or manipulated by inputs"

_env_info() {
	printf '%s\n' "container_name=qbt_builder" >> "$GITHUB_ENV"
	printf '%s\n' "wd=$wd" >> "$GITHUB_ENV"
}

# start creating our base docker command
docker_command=("run" "-it" "-d" "--name" "qbt_builder")

# Parse the custom docker commands string into an array
read -ra inputs_custom_docker_commands_array <<< "$inputs_custom_docker_commands"

if [[ $inputs_use_host_env == 'true' ]]; then
	env > "${workspace}/env.host"
fi

if [[ -f "${workspace}/env.host" && -f "${workspace}/env.custom" ]]; then
	cat "${workspace}/env.host" "${workspace}/env.custom" > "${workspace}/env.load"
	env_custom="host + custom"
elif [[ -f "${workspace}/env.host" && ! -f "${workspace}/env.custom" ]]; then
	cat "${workspace}/env.host" > "${workspace}/env.load"
	env_custom="host only"
elif [[ ! -f "${workspace}/env.host" && -f "${workspace}/env.custom" ]]; then
	cat "${workspace}/env.custom" > "${workspace}/env.load"
	env_custom="custom only"
else
	env_custom="none"
fi

# Only add env-file if merged file exists
if [[ -f "${workspace}/env.load" ]]; then
	docker_command+=("--env-file" "${workspace}/env.load")
fi

###
### Fast-path: if the user supplied a Dockerfile, ignore other inputs except env related
###

if [[ -n $inputs_dockerfile ]]; then
	dockerfile_path="${workspace}/qbt_builder_dockerfile"
	log_info "Fast-path: using provided Dockerfile: $inputs_dockerfile"

	case "$inputs_dockerfile" in
		http://* | https://*)
			log_info "Downloading Dockerfile from URL: $inputs_dockerfile"
			curl -fsSL "$inputs_dockerfile" -o "$dockerfile_path" || {
				log_error "Failed to download Dockerfile from $inputs_dockerfile"
				exit 1
			}
			;;
		*)
			if [[ -f $inputs_dockerfile ]]; then
				cp "$inputs_dockerfile" "$dockerfile_path" || {
					log_error "Failed to copy Dockerfile from $inputs_dockerfile to $dockerfile_path"
					exit 1
				}
			elif [[ -f "$workspace/$inputs_dockerfile" ]]; then
				cp "$workspace/$inputs_dockerfile" "$dockerfile_path" || {
					log_error "Failed to copy Dockerfile from $workspace/$inputs_dockerfile to $dockerfile_path"
					exit 1
				}
			else
				log_error "Dockerfile not found at '$inputs_dockerfile' or '$workspace/$inputs_dockerfile'"
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
	docker build -f "$dockerfile_path" -t "$custom_image_tag" . || {
		log_error "Failed to build Docker image from provided Dockerfile"
		# Clean up Dockerfile if left behind
		rm -f "$dockerfile_path"
		exit 1
	}

	docker_command+=("$custom_image_tag")

	# Start a container (detached) from the built image so it's running like a daemon.
	log_info "Starting container from image '$custom_image_tag' as 'qbt_builder' (detached)"
	docker "${docker_command[@]}" || {
		log_error "Failed to start container from image $custom_image_tag"
		rm -f "$dockerfile_path"
		exit 1
	}

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

# Add user specification based on image type
if [[ $inputs_os_id == ghcr.io/userdocs/* ]]; then
	if [[ $inputs_use_root == "false" ]]; then
		docker_command+=("-u" "1001:1001")
	fi
fi

if [[ $inputs_use_root == "true" ]]; then
	docker_command+=("-w" "/root")
else
	docker_command+=("-w" "/home/gh")
fi

docker_command+=("-v" "$workspace:/root")

if [[ $inputs_os_id == ghcr.io/userdocs/* ]]; then
	docker_command+=(
		"-v" "$workspace:/home/gh"
		"-v" "$workspace:/home/github"
		"-v" "$workspace:/home/username"
	)
fi

if [[ $inputs_os_id != ghcr.io/userdocs/* ]]; then
	docker_command+=(
		"-v" "$workspace:/home/gh"
	)
fi

docker_command+=(
	"${inputs_custom_docker_commands_array[@]}"
)

# Determine user setup for non-userdocs images
if [[ $inputs_os_id != ghcr.io/userdocs/* ]]; then
	# Create Dockerfile and build image with user setup
	dockerfile_path="${workspace}/qbt_builder_dockerfile"
	custom_image_tag="qbt_builder"

	case "$inputs_os_id" in
		alpine | */alpine)
			log_info "Creating Alpine Linux Dockerfile"
			printf '%b\n' "\`\`\`bash\n" >> "$GITHUB_STEP_SUMMARY"
			{
				# Avoid heredoc (EOF) which can break in some CI environments (GitHub Actions).
				# Build the Dockerfile lines in an array, use a single printf to print them.
				backslash=$'\\'
				df_lines=(
					"FROM ${inputs_os_id}:${inputs_os_version_id}"
					""
					"# Create group and user"
					"RUN addgroup -g 1001 gh 2>/dev/null || true && ${backslash}"
					"    adduser -h /home/gh -Ds /bin/bash -u 1001 -G 1001 gh"
					""
					"# Update packages and install dependencies"
					"RUN apk update --no-cache && ${backslash}"
					"    apk add -lu --no-cache sudo bash ${inputs_additional_alpine_apps} && ${backslash}"
					"    apk upgrade -l --no-cache"
					""
					"# Configure sudo access"
					"RUN umask 077 && ${backslash}"
					"    printf '%s\\n' \"gh ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/gh && ${backslash}"
					"    chmod 0440 /etc/sudoers.d/gh"
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
					"# Create group and user"
					"RUN groupadd -g 1001 gh 2>/dev/null || true && ${backslash}"
					"    useradd -ms /bin/bash -u 1001 -g 1001 gh"
					""
					"# Update packages and install dependencies"
					"RUN apt-get update && apt-get upgrade -y"
					""
					"# Install additional packages and sudo"
					"RUN apt-get install -y sudo ${inputs_additional_debian_apps}"
					""
					"# Configure sudo access"
					"RUN umask 077 && ${backslash}"
					"    printf '%s\\n' \"gh ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/gh && ${backslash}"
					"    chmod 0440 /etc/sudoers.d/gh"
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
					"# Create group and user (basic fallback)"
					"RUN groupadd 1001 2>/dev/null || addgroup 1001 2>/dev/null || true && ${backslash}"
					"    useradd -ms /bin/bash -u 1001 gh 2>/dev/null || adduser -h /home/gh -Ds /bin/bash -u 1001 gh 2>/dev/null || true"
					""
					"# Configure sudo access if sudo exists"
					"RUN if command -v sudo >/dev/null 2>&1; then ${backslash}"
					"        umask 077 && ${backslash}"
					"        printf '%s\\n' \"gh ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/gh && ${backslash}"
					"        chmod 0440 /etc/sudoers.d/gh; ${backslash}"
					"    fi"
				)
				printf '%s\n' "${df_lines[@]}"
			} | tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"
			printf '%b\n' '```' >> "$GITHUB_STEP_SUMMARY"
			;;
	esac

	# Build the custom image with user setup
	log_info "Building container image with user setup"
	docker build -f "$dockerfile_path" -t "$custom_image_tag" . || {
		log_error "Failed to build Docker image"
		exit 1
	}

	# Clean up the Dockerfile
	rm -f "$dockerfile_path"

	# Use the custom image and configure user for container run
	if [[ $inputs_use_root == "false" ]]; then
		docker_command+=("-u" "1001:1001")
	fi

	docker_command+=("$custom_image_tag")
else
	# For userdocs images, use original image
	docker_command+=("${inputs_os_id}:${inputs_os_version_id}")
fi

docker "${docker_command[@]}" || {
	log_error "Failed to create Docker container with command: ${docker_command[*]}"
	exit 1
}

for i in "${!docker_command[@]}"; do
	if [[ ${docker_command[i]} == "-w" ]]; then
		wd="${docker_command[i + 1]}"
		break
	fi
done

_inputs_info | tee -a "$GITHUB_STEP_SUMMARY"
_env_info
