#!/bin/bash

# Config (env-overridable)
inputs_use_host_env="${inputs_use_host_env:-none}"
inputs_uid="${inputs_uid:-0}"
inputs_gid="${inputs_gid:-0}"
inputs_container_name="${inputs_container_name:=builder}"
inputs_os_id="${inputs_os_id:=alpine}"
inputs_os_version_id="${inputs_os_version_id:=edge}"
inputs_custom_docker_commands="${inputs_custom_docker_commands:-}"
inputs_additional_alpine_apps="${inputs_additional_alpine_apps:-}"
inputs_additional_debian_apps="${inputs_additional_debian_apps:-}"
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

# Debug: Print all input variables
log_debug "Input variables:"
log_debug "  inputs_use_host_env='$inputs_use_host_env'"
log_debug "  inputs_uid='$inputs_uid'"
log_debug "  inputs_gid='$inputs_gid'"
log_debug "  inputs_container_name='$inputs_container_name'"
log_debug "  inputs_os_id='$inputs_os_id'"
log_debug "  inputs_os_version_id='$inputs_os_version_id'"
log_debug "  inputs_custom_docker_commands='$inputs_custom_docker_commands'"
log_debug "  inputs_additional_alpine_apps='$inputs_additional_alpine_apps'"
log_debug "  inputs_additional_debian_apps='$inputs_additional_debian_apps'"
log_debug "  workspace='$workspace'"

# Parse the custom docker commands string into an array
read -ra inputs_custom_docker_commands_array <<< "$inputs_custom_docker_commands"

# start creating our base docker command
docker_command=("run" "--name" "$inputs_container_name" "-it" "-d")

# Detect root mode once and reuse
if [[ $inputs_uid == "root" ]] || [[ $inputs_uid == "0" ]]; then
	use_root=true
else
	use_root=false
fi

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

# Only add LANG if OS is debian/ubuntu (supports repo-qualified names like something/debian)
case "$inputs_os_id" in
	debian | */debian | ubuntu | */ubuntu)
		docker_command+=("-e" "LANG=C.UTF-8")
		;;
esac

# Add user specification based on image type
if [[ $inputs_os_id == ghcr.io/userdocs/* ]]; then
	# For ghcr.io/userdocs images, use predefined users if not root
	if [[ $use_root == "false" ]]; then
		if [[ $inputs_uid =~ ^(gh|github|username)$ ]]; then
			docker_command+=("-u" "${inputs_uid}:${inputs_gid}")
		fi
	fi
fi

if [[ $use_root == "true" ]]; then
	docker_command+=("-w" "/root")
else
	docker_command+=("-w" "/home/${inputs_uid}")
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
		"-v" "$workspace:/home/$inputs_uid"
	)
fi

docker_command+=(
	"${inputs_custom_docker_commands_array[@]}"
	"${inputs_os_id}:${inputs_os_version_id}"
)

docker "${docker_command[@]}" || {
	log_error "Failed to create Docker container with command: ${docker_command[*]}"
	exit 1
}

if [[ $inputs_os_id != ghcr.io/userdocs/* ]]; then
	if [[ $use_root == "true" ]]; then
		new_user_name="gh" # Determine which user to create inside the container without mutating input variables
		new_uid=1001       # If running as root, create a helper user (gh:1001) for optional non-root execs which can bes used as exec -u gh:gh
		new_gid=1001       # If running as non-root, create the requested user (uid/gid provided by inputs)
	else
		new_user_name="$inputs_uid" # they provide a alpha numeric username
		new_uid="$inputs_gid"       # assume uid is sames at gid
		new_gid="$inputs_gid"       # so if they provide gh:1001 the end result will be gh 1001:1001
	fi

	# Create non-root user and install base pkgs (skip for userdocs images/root)
	case "$inputs_os_id" in
		alpine | */alpine)
			log_info "Setting up Alpine Linux container"
			docker exec -w "/" "$inputs_container_name" sh -c "addgroup -g ${new_gid} ${new_user_name} 2>/dev/null || true; adduser -h /home/${new_user_name} -Ds /bin/bash -u ${new_uid} -G ${new_user_name} ${new_user_name}" || {
				log_error "Failed to create user in Alpine container"
				exit 1
			}

			log_info "Updating package index and installing packages"
			docker exec -w "/" "$inputs_container_name" sh -c "apk update --no-cache && apk add -u --no-cache sudo bash ${inputs_additional_alpine_apps} && apk upgrade --no-cache" || {
				log_error "Failed to install/upgrade Alpine packages"
				exit 1
			}
			;;
		debian | */debian | ubuntu | */ubuntu)
			log_info "Setting up Debian/Ubuntu container"
			docker exec -w "/" "$inputs_container_name" sh -c "groupadd -g ${new_gid} ${new_user_name} 2>/dev/null || true; useradd -ms /bin/bash -u ${new_uid} -g ${new_gid} ${new_user_name}" || {
				log_error "Failed to create user in Debian/Ubuntu container"
				exit 1
			}

			log_info "Updating package index and installing packages"
			docker exec -w "/" "$inputs_container_name" sh -c "apt-get update && apt-get install -y sudo ${inputs_additional_debian_apps} && apt-get upgrade -y" || {
				log_error "Failed to install/upgrade Debian/Ubuntu packages"
				exit 1
			}
			;;
		*)
			log_info "Skipping package installation for unsupported OS: $inputs_os_id"
			;;
	esac

	docker exec -w "/" "$inputs_container_name" sh -c "umask 077; printf '%s\n' \"$new_user_name ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/$new_user_name; chmod 0440 /etc/sudoers.d/$new_user_name" || {
		log_error "Failed create password less sudo file"
		exit 1
	}

	# For non-ghcr.io/userdocs images running as non-root, restart container as the created user
	if [[ $use_root == "false" ]]; then
		if [[ -z $inputs_container_name ]]; then
			log_error "Container name is empty: inputs_container_name='$inputs_container_name'"
			exit 1
		fi

		log_info "Restarting container as user $inputs_uid"

		docker stop "$inputs_container_name" || {
			log_error "Failed to stop container"
			exit 1
		}

		docker commit "$inputs_container_name" "${inputs_os_id}:${inputs_os_version_id}" || {
			log_error "Failed to commit container changes"
			exit 1
		}

		docker rm "$inputs_container_name" || {
			log_error "Failed to remove old container"
			exit 1
		}

		# Insert user specification before the image name in the existing command
		# Find the position of the image name (last element) and insert -u before it
		image_name="${docker_command[-1]}"
		unset 'docker_command[-1]'                                   # Remove the image name
		docker_command+=("-u" "${new_uid}:${new_gid}" "$image_name") # Add -u and image back

		docker "${docker_command[@]}" || {
			log_error "Failed to restart Docker container with user"
			exit 1
		}

		log_info "Successfully restarted container as user $inputs_uid"
	fi
fi

for i in "${!docker_command[@]}"; do
	if [[ ${docker_command[i]} == "-w" ]]; then
		wd="${docker_command[i + 1]}"
		break
	fi
done

{
	printf '%b\n' "\`\`\`bash\n"
	printf '%s\n' "inputs_use_host_env=\"${inputs_use_host_env}\""
	printf '%s\n' "env_custom=\"${env_custom:-none}\""
	printf '%s\n' "inputs_uid=\"${inputs_uid}\""
	printf '%s\n' "inputs_gid=\"${inputs_gid}\""
	printf '%s\n' "inputs_container_name=\"${inputs_container_name}\""
	printf '%s\n' "inputs_os_id=\"${inputs_os_id}\""
	printf '%s\n' "inputs_os_version_id=\"${inputs_os_version_id}\""
	printf '%s\n' "inputs_custom_docker_commands=\"${inputs_custom_docker_commands}\""
	printf '%s\n' "inputs_additional_debian_apps=\"${inputs_additional_debian_apps}\""
	printf '%s\n' "inputs_additional_alpine_apps=\"${inputs_additional_alpine_apps}\""
	printf '%s\n' "workspace=\"${workspace}\""
	printf '%s\n' "docker_command=\"${docker_command[*]}\""
	printf '%s\n' "wd=\"${wd}\""
	printf '%b\n' '```'
} >> "$GITHUB_STEP_SUMMARY"

# Set outputs
{
	printf '%s\n' "container_name=$inputs_container_name"
	printf '%s\n' "uid=$inputs_uid"
	printf '%s\n' "wd=$wd"
} >> "$GITHUB_OUTPUT"
