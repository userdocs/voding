#!/bin/bash
# Quick installer for qbittorrent-nox-static
# This script is focused on being a simple installer that verifies installation and binaries

# Temporary download path tracked for EXIT trap cleanup
tmp_path=""

# Error handling function to test commands and exit with helpful explanations
handle_error() {
	local exit_code="$1"
	local command="$2"
	local context="$3"

	if [[ $exit_code -ne 0 ]]; then
		print_failure "Command failed: $command"
		print_error "Context: $context"
		print_error "Exit code: $exit_code"
		print_error "This error occurred during the installation process."
		print_error "Please check your system configuration and try again."
		exit "$exit_code"
	fi
}

# Check supported distributions
check_supported_distro() {
	# Localize ID and ID_LIKE so caller env cannot spoof distro checks and globals stay clean
	local ID="" ID_LIKE=""

	if [[ -f /etc/os-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
		# Support Alpine or Debian-based distributions (match ID_LIKE as whitespace-delimited tokens)
		if [[ ${ID:-} =~ ^(alpine|debian)$ ]] || [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
			return 0 # Supported distribution
		else
			print_error "Unsupported distribution: ${ID:-unknown}. This installer only supports Alpine or Debian-based distributions"
			exit 1
		fi
	else
		print_error "Cannot determine distribution. /etc/os-release not found"
		print_error "This installer only supports Alpine or Debian-based distributions"
		exit 1
	fi
}

# Color definitions for output formatting
readonly color_info='\033[0;94m'    # blue
readonly color_warning='\033[1;93m' # yellow
readonly color_error='\033[0;91m'   # red
readonly color_success='\033[0;92m' # green
readonly color_failure='\033[0;91m' # red
readonly color_action='\033[0;96m'  # cyan
readonly color_reset='\033[0m'      # reset

readonly unicode_red_light_circle="\e[91m\U2B24\e[0m"
readonly unicode_green_light_circle="\e[92m\U2B24\e[0m"
readonly unicode_yellow_light_circle="\e[93m\U2B24\e[0m"
readonly unicode_blue_light_circle="\e[94m\U2B24\e[0m"
readonly unicode_cyan_light_circle="\e[96m\U2B24\e[0m"
readonly unicode_grey_light_circle="\e[97m\U2B24\e[0m"

# Output functions for user feedback
print_output() {
	local type="$1"
	local message="$2"
	local icon color

	case "$type" in
		INFO)
			icon="${unicode_blue_light_circle}"
			color="$color_info"
			;;
		ACTION)
			icon="${unicode_cyan_light_circle}"
			color="$color_action"
			;;
		WARNING)
			icon="${unicode_yellow_light_circle}"
			color="$color_warning"
			;;
		ERROR)
			icon="${unicode_red_light_circle}"
			color="$color_error"
			;;
		SUCCESS)
			icon="${unicode_green_light_circle}"
			color="$color_success"
			;;
		FAILURE)
			icon="${unicode_red_light_circle}"
			color="$color_failure"
			;;
		*)
			icon="${unicode_grey_light_circle}"
			color=""
			;;
	esac

	# Colorize message suffix after ': ' if present; use %s for message text to prevent escape injection
	if [[ $message == *": "* ]]; then
		local prefix="${message%%: *}:"
		local suffix="${message#*: }"
		printf '%b %s %b%s %b\n' "$color $icon" "$prefix" "$color" "$suffix" "$color_reset" >&2
	else
		printf '%b %s%b\n' "$color $icon" "$message" "$color_reset" >&2
	fi
}

# Convenience wrappers
print_info() { print_output "INFO" "$1"; }
print_action() { print_output "ACTION" "$1"; }
print_warning() { print_output "WARNING" "$1"; }
print_error() { print_output "ERROR" "$1"; }
print_success() { print_output "SUCCESS" "$1"; }
print_failure() { print_output "FAILURE" "$1"; }
print_generic() { print_output "" "$1"; }

# Detect architecture and map to binary name
detect_arch() {
	local arch_output=""

	# Try different architecture detection methods
	# Prioritize distribution-specific tools for better accuracy
	if command -v apk > /dev/null 2>&1; then
		# Alpine Linux
		arch_output="$(apk --print-arch 2> /dev/null)" || {
			print_error "Failed to detect architecture using apk"
			exit 1
		}
	elif command -v dpkg > /dev/null 2>&1; then
		# Debian-based systems
		arch_output="$(dpkg --print-architecture 2> /dev/null)" || {
			print_error "Failed to detect architecture using dpkg"
			exit 1
		}
	elif command -v arch > /dev/null 2>&1; then
		# Fallback to arch command
		arch_output="$(arch)" || {
			print_error "Failed to detect architecture using arch command"
			exit 1
		}
	else
		print_error "No architecture detection tool found (apk/dpkg/arch)"
		print_error "Please install the appropriate package manager or set FORCE_ARCH environment variable"
		exit 1
	fi

	case "$arch_output" in
		# x86_64 = amd64, x86_64
		x86_64 | amd64) printf '%s' "x86_64" ;;
		# x86 = x86, i386, i686
		x86 | i386 | i686) printf '%s' "x86" ;;
		# aarch64 = arm64, aarch64
		aarch64 | arm64) printf '%s' "aarch64" ;;
		# armv7 = armv7* (and armhf on Debian/Ubuntu)
		armv7*) printf '%s' "armv7" ;;
		# armhf = armhf (on Alpine = armv6), armv6*, armel
		armhf)
			# Alpine uses apk, Debian/Ubuntu use dpkg
			if command -v apk > /dev/null 2>&1; then
				printf '%s' "armhf" # Alpine: armhf stays as armhf (armv6 binary)
			else
				printf '%s' "armv7" # Debian/Ubuntu: armhf maps to armv7 binary
			fi
			;;
		armv6* | armel) printf '%s' "armhf" ;;
		# riscv64 = riscv64
		riscv64) printf '%s' "riscv64" ;;
		*)
			print_error "Unsupported architecture: $arch_output"
			print_error "Supported architectures: x86_64, x86, aarch64, armv7, armhf, riscv64"
			print_error "You can override with FORCE_ARCH environment variable"
			exit 1
			;;
	esac
}

# Validate an architecture name against the published binaries
validate_arch() {
	case "$1" in
		x86_64 | x86 | aarch64 | armv7 | armhf | riscv64) return 0 ;;
		*)
			print_error "Unsupported architecture: $1"
			print_error "Supported architectures: x86_64, x86, aarch64, armv7, armhf, riscv64"
			return 1
			;;
	esac
}

# Remove the temporary download if the script exits before installing it
cleanup_tmp() {
	if [[ -n ${tmp_path:-} ]]; then
		rm -f -- "$tmp_path"
	fi
}

# Check for wget or curl, default to curl if present
check_download_tools() {
	if command -v curl > /dev/null 2>&1; then
		printf '%s' "curl"
	elif command -v wget > /dev/null 2>&1; then
		printf '%s' "wget"
	else
		print_error "No download tool found. Please install curl or wget"
		print_error "On Alpine: apk add curl"
		print_error "On Debian/Ubuntu: apt-get install curl"
		exit 1
	fi
}

# Check if gh CLI is available
check_gh_cli() {
	if command -v gh > /dev/null 2>&1; then
		return 0
	else
		return 1
	fi
}

# Create download function based on architecture checks
create_download_url() {
	local arch="$1"
	local release_tag="$2"
	printf '%s' "https://github.com/userdocs/qbittorrent-nox-static/releases/download/${release_tag}/${arch}-qbittorrent-nox"
}

# Create SHA256 checksum of downloaded file
create_sha256() {
	local file_path="$1"
	local safe_path="$file_path"
	local raw_out digest

	if [[ ! -f $file_path ]]; then
		print_error "File not found for checksum: $file_path"
		return 1
	fi

	# Guard against filenames starting with '-' across GNU, BSD, and BusyBox tools
	[[ $safe_path == -* ]] && safe_path="./$safe_path"

	if command -v sha256sum > /dev/null 2>&1; then
		raw_out=$(sha256sum "$safe_path" 2> /dev/null) || {
			print_error "Failed to calculate SHA256 checksum: $file_path"
			return 1
		}
	elif command -v shasum > /dev/null 2>&1; then
		raw_out=$(shasum -a 256 "$safe_path" 2> /dev/null) || {
			print_error "Failed to calculate SHA256 checksum: $file_path"
			return 1
		}
	else
		print_warning "No SHA256 tool found (sha256sum/shasum) - skipping checksum"
		return 1
	fi

	# GNU sha256sum/shasum prefixes lines with '\' when the path contains backslashes or newlines
	raw_out="${raw_out#\\}"
	digest="${raw_out%% *}"
	digest="${digest,,}"

	if [[ ! $digest =~ ^[0-9a-f]{64}$ ]]; then
		print_error "Invalid SHA256 output for: $file_path"
		return 1
	fi

	printf '%s\n' "$digest"
}

# Comprehensive SHA256 verification function
# Tries GitHub CLI first, then API, then shows local SHA as fallback
# Returns 0 verified, 1 could not verify, 2 checksum mismatch
verify_binary_integrity() {
	local install_path="$1"
	local release_tag="$2"
	local arch="$3"
	local repo="userdocs/qbittorrent-nox-static"
	local expected_asset="${arch}-qbittorrent-nox"

	# Calculate local file SHA256
	local local_sha
	if ! local_sha=$(create_sha256 "$install_path"); then
		print_warning "Could not calculate local SHA256 - skipping verification"
		return 1
	fi

	print_info "SHA256: $local_sha"

	# Try GitHub CLI attestation verification first (most secure)
	if check_gh_cli; then
		print_action "Verifying with GitHub CLI attestations..."
		if gh attestation verify "$install_path" --repo "$repo" 2> /dev/null; then
			print_success "GitHub CLI attestation verification passed"
			return 0
		else
			print_warning "GitHub CLI attestation verification failed or not available"
			print_action "Falling back to GitHub API verification..."
		fi
	else
		if [[ -n ${GITHUB_ACTIONS:-} ]]; then
			print_info "GitHub Actions detected but gh CLI not found"
			print_info "Note: GitHub CLI may need to be explicitly installed in your workflow"
			print_info "Note: GH_TOKEN environment variable is also required for attestation verification"
		else
			print_info "GitHub CLI not found - trying GitHub API verification..."
		fi
	fi

	# Try GitHub API verification as fallback
	local api_url="https://api.github.com/repos/${repo}/releases/tags/${release_tag}"
	local tool
	tool=$(check_download_tools) || exit 1

	print_action "Verifying SHA256 against GitHub API..."

	# Fetch release assets from GitHub API
	local api_response
	case "$tool" in
		wget)
			api_response=$(wget -qO- "$api_url" 2> /dev/null) || {
				print_warning "Failed to fetch release information from GitHub API"
				print_info "Local SHA256 verification completed"
				return 1
			}
			;;
		curl)
			api_response=$(curl -fsSL "$api_url" 2> /dev/null) || {
				print_warning "Failed to fetch release information from GitHub API"
				print_info "Local SHA256 verification completed"
				return 1
			}
			;;
	esac

	if [[ -z $api_response ]]; then
		print_warning "Empty response from GitHub API"
		print_info "Local SHA256 verification completed"
		return 1
	fi

	# Extract SHA256 digests from API response; bind to exact asset name when present
	local raw_digests=""
	if command -v jq > /dev/null 2>&1; then
		if jq -e --arg name "$expected_asset" '(.assets // []) | any(.name == $name)' <<< "$api_response" > /dev/null 2>&1; then
			raw_digests=$(jq -r --arg name "$expected_asset" '(.assets // [])[] | select(.name == $name) | .digest // empty' <<< "$api_response" 2> /dev/null)
		else
			raw_digests=$(jq -r '(.assets // [])[].digest // empty' <<< "$api_response" 2> /dev/null)
		fi
	else
		local flat_json="${api_response//[$'\r\n']/ }"
		if [[ $flat_json =~ \"name\"[[:space:]]*:[[:space:]]*\"${expected_asset}\"(.*)$ ]]; then
			local rest="${BASH_REMATCH[1]}"
			rest="${rest%%\"name\"*}"
			rest=$(sed -E 's/\}[[:space:]]*\].*//' <<< "$rest")
			raw_digests=$(grep -Eo 'sha256:[0-9a-fA-F]{64}' <<< "$rest" 2> /dev/null)
		else
			raw_digests=$(grep -Eo 'sha256:[0-9a-fA-F]{64}' <<< "$api_response" 2> /dev/null)
		fi
	fi

	# Normalize digests (strip sha256: prefix and lowercase)
	local api_digests="" api_digest
	while IFS= read -r api_digest; do
		[[ -z $api_digest ]] && continue
		api_digest="${api_digest#sha256:}"
		api_digest="${api_digest,,}"
		if [[ $api_digest =~ ^[0-9a-f]{64}$ ]]; then
			api_digests+="${api_digests:+$'\n'}${api_digest}"
		fi
	done <<< "$raw_digests"

	if [[ -z $api_digests ]]; then
		print_warning "No SHA256 digests found in GitHub API response"
		print_info "This may be normal for older releases or if digests are not published"
		print_info "Local SHA256 verification completed"
		return 1
	fi

	# Check if local SHA256 matches the expected API digest(s)
	local match_found=false
	while IFS= read -r api_digest; do
		if [[ -n $api_digest ]] && [[ $local_sha == "$api_digest" ]]; then
			match_found=true
			break
		fi
	done <<< "$api_digests"

	if [[ $match_found == "true" ]]; then
		print_success "GitHub API SHA256 verification passed"
		return 0
	else
		print_warning "GitHub API SHA256 verification failed"
		print_warning "Local SHA256:  $local_sha"
		print_warning "API Digests:"
		while IFS= read -r api_digest; do
			if [[ -n $api_digest ]]; then
				print_warning "  $api_digest"
			fi
		done <<< "$api_digests"
		print_warning "This may indicate a corrupted download or outdated API data"
		return 2
	fi
}

# Get release tag from API
get_release_tag() {
	local api="https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/dependency-version.json"
	local ver="${LIBTORRENT_VERSION:-v2}"
	local json_key

	# Validate requested LibTorrent version before making network calls
	# v1 = 1.2, v2 = 2.1 (default), 2.0 must be requested explicitly
	case "$ver" in
		v1 | v1.2 | 1.2) json_key="libtorrent_1_2" ;;
		v2.0 | 2.0) json_key="libtorrent_2_0" ;;
		v2 | v2.1 | 2.1) json_key="libtorrent_2_1" ;;
		*)
			print_error "Invalid LibTorrent version: $ver"
			print_error "Valid options: v1/v1.2/1.2, v2.0/2.0, v2/v2.1/2.1"
			exit 1
			;;
	esac

	local tool
	tool=$(check_download_tools) || exit 1

	# Fetch API response
	local response
	case "$tool" in
		wget)
			response=$(wget -qO- "$api" 2> /dev/null) || {
				handle_error $? "wget -qO- $api" "Failed to fetch release information from API"
			}
			;;
		curl)
			response=$(curl -fsSL "$api" 2> /dev/null) || {
				handle_error $? "curl -fsSL $api" "Failed to fetch release information from API"
			}
			;;
	esac

	if [[ -z $response ]]; then
		print_error "Failed to fetch release information - empty response"
		print_error "API endpoint: $api"
		exit 1
	fi

	# Parse release tag (works on pretty-printed, compact, and trailing-comma-free JSON)
	local qbt_ver libt_ver
	qbt_ver=$(sed -En 's/.*"qbittorrent"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "$response" | head -n 1)
	libt_ver=$(sed -En "s/.*\"${json_key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" <<< "$response" | head -n 1)

	if [[ -z $qbt_ver ]] || [[ -z $libt_ver ]]; then
		print_error "Failed to parse version information from API response"
		print_error "qBittorrent version: ${qbt_ver:-not found}"
		print_error "LibTorrent version: ${libt_ver:-not found}"
		exit 1
	fi

	# Validate parsed version tokens to prevent URL path traversal or terminal injection
	if [[ ! $qbt_ver =~ ^[0-9A-Za-z._+-]+$ || $qbt_ver == *..* ]] \
		|| [[ ! $libt_ver =~ ^[0-9A-Za-z._+-]+$ || $libt_ver == *..* ]]; then
		print_error "Failed to parse version information from API response: invalid version format"
		exit 1
	fi

	# Parse revision field
	local revision
	revision=$(sed -En 's/.*"revision"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' <<< "$response" | head -n 1)
	if [[ -z $revision ]]; then
		print_warning "Failed to parse revision from API response"
	elif [[ ! $revision =~ ^[0-9A-Za-z._+-]+$ || $revision == *..* ]]; then
		print_warning "Failed to parse revision from API response"
		revision=""
	fi

	# Output release tag and revision
	printf '%s %s' "release-${qbt_ver}_v${libt_ver}" "${revision:-}"
}

# Download file
download() {
	local url="$1"
	local output="$2"
	local tool
	tool=$(check_download_tools) || exit 1

	print_action "Downloading: $url"
	case "$tool" in
		wget)
			wget -qO "$output" "$url" || {
				handle_error $? "wget -qO $output $url" "Failed to download binary"
			}
			;;
		curl)
			curl -fsSL -o "$output" "$url" || {
				handle_error $? "curl -fsSL -o $output $url" "Failed to download binary"
			}
			;;
	esac

	# Verify download was successful
	if [[ ! -f $output ]] || [[ ! -s $output ]]; then
		print_failure "Download failed or file is empty: $output"
		print_error "URL: $url"
		print_error "Please check your internet connection and try again"
		exit 1
	fi
}

# Main installation
main() {
	# Require HOME to be set to avoid defaulting install paths to /bin
	if [[ -z ${HOME:-} ]]; then
		print_error "HOME environment variable is not set"
		exit 1
	fi

	# Check if running on supported distribution
	check_supported_distro

	print_info "qBittorrent-nox Static Binary Installer"
	print_generic "======================================="

	# exit inside $(...) only ends the subshell, so check each capture
	local arch="${FORCE_ARCH:-}"
	if [[ -z $arch ]]; then
		arch=$(detect_arch) || exit 1
	else
		validate_arch "$arch" || exit 1
	fi
	local bin_dir="${HOME%/}/bin"
	local install_path="${bin_dir}/qbittorrent-nox"
	# Get release and download
	local release_tag revision release_info libtorrent_ver
	release_info=$(get_release_tag) || exit 1
	read -r release_tag revision <<< "$release_info"
	# Resolved version from the tag, e.g. release-5.3.0_v2.1.2 -> 2.1.2
	libtorrent_ver="${release_tag##*_v}"

	print_info "Architecture: $arch"
	print_info "LibTorrent version: $libtorrent_ver"
	# Output revision if available
	if [[ -n $revision ]]; then
		print_info "Build revision: $revision"
	fi
	print_info "Attestation verification: $(check_gh_cli && printf '%s' "enabled" || printf '%s' "disabled (gh cli not found)")"

	# Prepare installation directory
	print_action "Creating install directory: $bin_dir"
	mkdir -p "$bin_dir" || {
		handle_error $? "mkdir -p $bin_dir" "Failed to create installation directory"
	}

	# Get release and download
	local url
	url=$(create_download_url "$arch" "$release_tag")

	# Download to a temp file so a failed download never clobbers a working install
	tmp_path=""
	trap cleanup_tmp EXIT
	tmp_path=$(mktemp "${bin_dir}/.qbittorrent-nox.XXXXXX") || {
		handle_error $? "mktemp ${bin_dir}/.qbittorrent-nox.XXXXXX" "Failed to create temporary file"
	}
	download "$url" "$tmp_path"

	# Verify binary integrity (SHA256 + attestations) before marking executable or installing
	local integrity_failed=false integrity_rc=0
	verify_binary_integrity "$tmp_path" "$release_tag" "$arch" || integrity_rc=$?
	if [[ $integrity_rc -eq 2 ]]; then
		print_failure "Checksum mismatch: refusing to install the downloaded binary"
		exit 1
	elif [[ $integrity_rc -ne 0 ]]; then
		integrity_failed=true
	fi

	# Set executable permissions only after integrity check succeeds or passes fallback
	print_action "Setting executable permissions for: $install_path"
	chmod 755 "$tmp_path" || {
		handle_error $? "chmod 755 $tmp_path" "Failed to set executable permissions"
	}

	mv -f "$tmp_path" "$install_path" || {
		handle_error $? "mv -f $tmp_path $install_path" "Failed to install binary"
	}
	tmp_path=""
	trap - EXIT

	print_success "Installation complete: $install_path"

	# Test binary
	local test_output test_exit_code binary_failed=false
	test_output=$("$install_path" --version 2>&1)
	test_exit_code=$?

	if [[ $test_exit_code -eq 0 ]]; then
		local version_info="${test_output%%$'\n'*}"
		print_success "Binary test passed"
		print_info "Version: $version_info"
	else
		binary_failed=true
		print_warning "Binary test failed"
		if [[ $test_output == *"Exec format error"* ]]; then
			print_error "Architecture mismatch detected - wrong binary for your system"
			print_info "Solution: Install qemu-user-static to run different architectures"
			print_info "  - On Alpine: apk add qemu-user-static"
			print_info "  - On Debian/Ubuntu: apt-get install qemu-user-static"
		else
			print_warning "The binary may not be compatible with your system"
			print_info "Try: ldd $install_path (to check missing libraries)"
		fi
	fi

	# PATH check
	if [[ ":${PATH:-}:" != *":${bin_dir}:"* && ":${PATH:-}:" != *":${bin_dir}/:"* ]]; then
		# shellcheck disable=SC2016
		print_warning '$HOME/bin is not in your PATH'
		# shellcheck disable=SC2016
		print_info 'Add to ~/.bashrc: export PATH="$HOME/bin:$PATH"'
		print_info 'Then run: source ~/.bashrc'
	fi

	# Final status message
	if [[ $integrity_failed == true ]] || [[ $binary_failed == true ]]; then
		print_warning "Installation completed with errors!"
		if [[ $binary_failed == true ]]; then
			print_info "Binary test failed - the application may not work properly"
		fi
		if [[ $integrity_failed == true ]]; then
			print_info "Integrity could not be verified - consider verifying manually"
		fi
	else
		print_success "Installation completed successfully!"
	fi
	print_info "Run with: qbittorrent-nox"
}

# Simple argument parsing: loop through all args
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h | --help)
				cat <<- EOF

					Usage: qi.bash [OPTIONS]

					Options:

					  -lt | --libtorrent VER   LibTorrent version (v1/v1.2/1.2, v2.0/2.0, v2/v2.1/2.1) [default: v2]
					  -fa | --force-arch ARCH  Force architecture (x86_64, x86, aarch64, armv7, armhf, riscv64) [ENV: FORCE_ARCH]
					  -h  | --help             Show this help

					Environment Variables:

					  LIBTORRENT_VERSION       LibTorrent version (v1/v1.2/1.2, v2.0/2.0, v2/v2.1/2.1) [default: v2]
					  FORCE_ARCH               Force architecture (x86_64, x86, aarch64, armv7, armhf, riscv64)

					Examples:

					  ./qi.bash                # Install with LibTorrent 2.1 (v2)
					  ./qi.bash -lt v1         # Install with LibTorrent 1.2
					  ./qi.bash -lt 2.0        # Install with LibTorrent 2.0
					  ./qi.bash -fa armv7      # Force armv7 architecture

				EOF
				exit 0
				;;
			-lt | --libtorrent)
				if [[ $# -lt 2 ]]; then
					print_error "Option $1 requires a version. Invalid libtorrent version: missing"
					exit 1
				fi
				shift
				case "${1:-}" in
					v1 | v1.2 | 1.2 | v2.0 | 2.0 | v2 | v2.1 | 2.1) LIBTORRENT_VERSION="$1" ;;
					*)
						print_error "Invalid libtorrent version: ${1:-}. Use: v1/v1.2/1.2, v2.0/2.0 or v2/v2.1/2.1"
						exit 1
						;;
				esac
				;;
			--libtorrent=*)
				lt_arg="${1#*=}"
				case "$lt_arg" in
					v1 | v1.2 | 1.2 | v2.0 | 2.0 | v2 | v2.1 | 2.1) LIBTORRENT_VERSION="$lt_arg" ;;
					*)
						print_error "Invalid libtorrent version: $lt_arg. Use: v1/v1.2/1.2, v2.0/2.0 or v2/v2.1/2.1"
						exit 1
						;;
				esac
				;;
			-fa | --force-arch)
				if [[ $# -lt 2 || -z ${2:-} ]]; then
					print_error "Option $1 requires an architecture. Use -h or --help for usage"
					exit 1
				fi
				shift
				validate_arch "$1" || exit 1
				FORCE_ARCH="$1"
				;;
			--force-arch=*)
				fa_arg="${1#*=}"
				if [[ -z $fa_arg ]]; then
					print_error "Option --force-arch requires an architecture. Use -h or --help for usage"
					exit 1
				fi
				validate_arch "$fa_arg" || exit 1
				FORCE_ARCH="$fa_arg"
				;;
			*)
				print_error "Unknown option: $1. Use -h or --help for usage"
				exit 1
				;;
		esac
		shift
	done

	main
fi
