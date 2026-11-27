#!/bin/bash
#
# Test suite for actions/qbt_docker/action.bash
#
# Tests run as black-box subprocess invocations with a mock docker binary.
# GitHub Actions env vars (GITHUB_ENV, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY,
# GITHUB_WORKSPACE) point at temp files for each test invocation.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/action.bash"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

pass_count=0
fail_count=0

#=============================================================================
# TEST HELPERS
#=============================================================================

_pass() {
	pass_count=$((pass_count + 1))
	printf '  \033[32m✓ PASS\033[0m\n'
}

_fail() {
	fail_count=$((fail_count + 1))
	printf '  \033[31mFAIL: %s\033[0m\n' "$1"
	if [[ -n ${2:-} ]]; then
		printf '  Actual output:\n'
		printf '%s\n' "$2" | tail -5 | sed 's/^/    /'
	fi
}

section() {
	printf '\n\033[1m── %s \033[0m\n\n' "$1"
}

# Invoke the script as a subprocess.
# Usage: invoke_script [--workspace DIR] [KEY=VAL ...]
# Stdout+stderr go to $tmp_dir/last_output.  Resets gh env files and docker logs each call.
invoke_script() {
	local ws_dir="${tmp_dir}/ws"
	local custom_ws=false
	local -a extra_env=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--workspace)
				ws_dir="$2"
				custom_ws=true
				shift 2
				;;
			*)
				extra_env+=("$1")
				shift
				;;
		esac
	done

	if [[ $custom_ws == false ]]; then
		rm -rf "$ws_dir"
	fi
	if [[ $ws_dir == /* ]]; then
		mkdir -p "$ws_dir"
	fi

	: > "${tmp_dir}/gh_env"
	: > "${tmp_dir}/gh_output"
	: > "${tmp_dir}/gh_summary"
	: > "${tmp_dir}/docker_calls.log"
	rm -f "${tmp_dir}/last_dockerfile"

	env -i \
		HOME="${HOME:-/root}" \
		PATH="${tmp_dir}:${PATH}" \
		GITHUB_WORKSPACE="$ws_dir" \
		GITHUB_ENV="${tmp_dir}/gh_env" \
		GITHUB_OUTPUT="${tmp_dir}/gh_output" \
		GITHUB_STEP_SUMMARY="${tmp_dir}/gh_summary" \
		RUNNER_ARCH="X64" \
		inputs_os_id="alpine" \
		inputs_os_version_id="edge" \
		inputs_use_host_env="false" \
		inputs_use_root="false" \
		"${extra_env[@]}" \
		bash "$script_path" > "${tmp_dir}/last_output" 2>&1
}

last_output() { cat "${tmp_dir}/last_output"; }
docker_log() { cat "${tmp_dir}/docker_calls.log" 2> /dev/null; }
reset_docker_log() { : > "${tmp_dir}/docker_calls.log"; }

# Assert exit code.
run_test() {
	local name="$1"
	local expected_exit="$2"
	shift 2
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	invoke_script "$@"
	local actual=$?
	if [[ $actual -eq $expected_exit ]]; then
		_pass
	else
		_fail "expected exit $expected_exit, got $actual" "$(last_output)"
	fi
}

# Assert stdout/stderr of an invoke_script call contains a grep pattern.
assert_output() {
	local name="$1"
	local pattern="$2"
	shift 2
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	invoke_script "$@"
	local plain
	plain=$(last_output | sed 's/\x1b\[[0-9;]*m//g')
	if printf '%s' "$plain" | grep -q -- "$pattern"; then
		_pass
	else
		_fail "output did not contain: $pattern" "$plain"
	fi
}

# Post-invoke: assert GITHUB_OUTPUT contains an exact string.
assert_gh_output() {
	local name="$1"
	local pattern="$2"
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	if grep -qF -- "$pattern" "${tmp_dir}/gh_output" 2> /dev/null; then
		_pass
	else
		_fail "GITHUB_OUTPUT did not contain: $pattern" "$(cat "${tmp_dir}/gh_output" 2> /dev/null)"
	fi
}

# Post-invoke: assert docker_calls.log contains a substring.
assert_docker() {
	local name="$1"
	local pattern="$2"
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	# Use -- to prevent grep treating patterns like '--env-file' as options.
	if grep -qF -- "$pattern" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
		_pass
	else
		_fail "docker was not called with: $pattern" "$(docker_log)"
	fi
}

# Post-invoke: assert the saved Dockerfile contains a pattern.
assert_dockerfile() {
	local name="$1"
	local pattern="$2"
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	if [[ -f "${tmp_dir}/last_dockerfile" ]] && grep -qE -- "$pattern" "${tmp_dir}/last_dockerfile" 2> /dev/null; then
		_pass
	else
		_fail "Dockerfile did not contain: $pattern" "$(cat "${tmp_dir}/last_dockerfile" 2> /dev/null)"
	fi
}

# Post-invoke: assert the saved Dockerfile exists and does NOT contain a pattern.
assert_not_dockerfile() {
	local name="$1"
	local pattern="$2"
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	if [[ ! -f "${tmp_dir}/last_dockerfile" ]]; then
		_fail "Dockerfile was not captured (build may not have run)" "$(last_output)"
	elif ! grep -qE -- "$pattern" "${tmp_dir}/last_dockerfile" 2> /dev/null; then
		_pass
	else
		_fail "Dockerfile should not contain: $pattern" "$(cat "${tmp_dir}/last_dockerfile" 2> /dev/null)"
	fi
}

#=============================================================================
# MOCK DOCKER SETUP
#=============================================================================

# Logs all calls to docker_calls.log.
# On 'build', copies the Dockerfile (-f arg) to last_dockerfile for inspection.
# Supports MOCK_BUILDX_JSON to return custom inspect JSON and MOCK_DOCKER_FAIL to simulate errors.
cat > "${tmp_dir}/docker" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${tmp_dir}/docker_calls.log"
case "\$1" in
	build)
		args=("\$@")
		for (( i=0; i<\${#args[@]}; i++ )); do
			if [[ "\${args[i]}" == "-f" ]]; then
				cp "\${args[i+1]}" "${tmp_dir}/last_dockerfile" 2>/dev/null
				break
			fi
		done
		[[ "\${MOCK_DOCKER_FAIL:-}" == "build" ]] && exit 1
		;;
	buildx)
		if [[ -n "\${MOCK_BUILDX_JSON:-}" ]]; then
			printf '%s\n' "\$MOCK_BUILDX_JSON"
		fi
		;;
	run)
		[[ "\${MOCK_DOCKER_FAIL:-}" == "run" ]] && exit 1
		;;
	*) ;;
esac
exit 0
EOF
chmod +x "${tmp_dir}/docker"

#=============================================================================
# TESTS
#=============================================================================

printf 'ACTION BASH TEST SUITE\n'
printf 'Script: %s\n' "$script_path"

#─────────────────────────────────────────────────────
section "Boolean Input Validation"
#─────────────────────────────────────────────────────

run_test "inputs_use_host_env=yes exits 1" 1 \
	inputs_use_host_env="yes"

run_test "inputs_use_host_env=TRUE exits 1" 1 \
	inputs_use_host_env="TRUE"

run_test "inputs_use_root=1 exits 1" 1 \
	inputs_use_root="1"

assert_output "boolean error message names the expected values" "must be 'true' or 'false'" \
	inputs_use_host_env="yes"

#─────────────────────────────────────────────────────
section "OS ID and Version ID Validation"
#─────────────────────────────────────────────────────

run_test "inputs_os_id with ! char exits 1" 1 \
	inputs_os_id="alpine!"

run_test "inputs_os_id over 128 chars exits 1" 1 \
	inputs_os_id="$(printf 'a%.0s' {1..129})"

run_test "inputs_os_version_id with ^ char exits 1" 1 \
	inputs_os_version_id="ver^1"

run_test "inputs_os_version_id over 64 chars exits 1" 1 \
	inputs_os_version_id="$(printf 'v%.0s' {1..65})"

run_test "inputs_os_id starting with hyphen exits 1" 1 \
	inputs_os_id="-f"

run_test "inputs_os_id with .. path segment exits 1" 1 \
	inputs_os_id="alpine/../debian"

run_test "arch-prefixed inputs_os_id with leading-hyphen image exits 1" 1 \
	inputs_os_id="arm64v8/-alpine"

run_test "inputs_os_version_id starting with hyphen exits 1" 1 \
	inputs_os_version_id="-edge"

run_test "workspace path containing colon exits 1" 1 \
	--workspace "${tmp_dir}/ws:bad"

run_test "relative workspace path exits 1" 1 \
	--workspace "relative_ws_dir"

run_test "root workspace path (/) exits 1" 1 \
	--workspace "/"

run_test "workspace resolving to / (/.) exits 1" 1 \
	--workspace "/."

# Symlinked GITHUB_ENV / GITHUB_OUTPUT / GITHUB_STEP_SUMMARY must be rejected without clobbering targets
printf 'KEEP_SAFE\n' > "${tmp_dir}/sym_gh_target"
ln -sf "${tmp_dir}/sym_gh_target" "${tmp_dir}/sym_gh_env"
ln -sf "${tmp_dir}/sym_gh_target" "${tmp_dir}/sym_gh_out"
ln -sf "${tmp_dir}/sym_gh_target" "${tmp_dir}/sym_gh_sum"

run_test "symlinked GITHUB_ENV exits 1" 1 \
	GITHUB_ENV="${tmp_dir}/sym_gh_env"

run_test "symlinked GITHUB_OUTPUT exits 1" 1 \
	GITHUB_OUTPUT="${tmp_dir}/sym_gh_out"

run_test "symlinked GITHUB_STEP_SUMMARY exits 1" 1 \
	GITHUB_STEP_SUMMARY="${tmp_dir}/sym_gh_sum"

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "symlinked GITHUB_* targets were not clobbered"
if [[ $(cat "${tmp_dir}/sym_gh_target") == "KEEP_SAFE" ]]; then
	_pass
else
	_fail "symlink target was modified" "$(cat "${tmp_dir}/sym_gh_target" 2> /dev/null)"
fi

# Directory or missing-parent GITHUB_ENV fails upfront before docker build/run
mkdir -p "${tmp_dir}/dir_gh_env"
run_test "directory GITHUB_ENV exits 1 before docker runs" 1 \
	GITHUB_ENV="${tmp_dir}/dir_gh_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "directory GITHUB_ENV prevented docker build/run"
if [[ ! -s "${tmp_dir}/docker_calls.log" ]]; then
	_pass
else
	_fail "docker was invoked despite invalid GITHUB_ENV" "$(docker_log)"
fi

run_test "missing parent dir for GITHUB_OUTPUT exits 1" 1 \
	GITHUB_OUTPUT="${tmp_dir}/no_such_dir/gh_out"

# Named pipe (FIFO) at GITHUB_ENV must exit 1 immediately without blocking
mkfifo "${tmp_dir}/fifo_gh_env"
run_test "named pipe (FIFO) GITHUB_ENV exits 1" 1 \
	GITHUB_ENV="${tmp_dir}/fifo_gh_env"

# /dev/null is accepted for GITHUB_ENV, GITHUB_OUTPUT, and GITHUB_STEP_SUMMARY
run_test "/dev/null accepted for GITHUB_ENV, GITHUB_OUTPUT, and GITHUB_STEP_SUMMARY" 0 \
	GITHUB_ENV="/dev/null" \
	GITHUB_OUTPUT="/dev/null" \
	GITHUB_STEP_SUMMARY="/dev/null"

#─────────────────────────────────────────────────────
section "Platform Validation"
#─────────────────────────────────────────────────────

run_test "inputs_platform=LINUX/AMD64 (uppercase) exits 1" 1 \
	inputs_platform="LINUX/AMD64"

# Locale-collation check: uppercase platform and non-ASCII package name must fail even under UTF-8 locales
_utf8_loc="C.UTF-8"
if locale -a 2> /dev/null | grep -qi '^en_US\.utf-\?8$'; then
	_utf8_loc=$(locale -a 2> /dev/null | grep -i '^en_US\.utf-\?8$' | head -1)
fi
run_test "inputs_platform=LINUX/AMD64 under UTF-8 locale exits 1" 1 \
	LC_ALL="$_utf8_loc" \
	LANG="$_utf8_loc" \
	inputs_platform="LINUX/AMD64"

run_test "non-ASCII package name under UTF-8 locale exits 1" 1 \
	LC_ALL="$_utf8_loc" \
	LANG="$_utf8_loc" \
	inputs_additional_apps=$'c\xc3\xbcrl'

run_test "inputs_platform=linux-amd64 (no slash) exits 1" 1 \
	inputs_platform="linux-amd64"

run_test "inputs_platform with 4 segments exits 1" 1 \
	inputs_platform="linux/arm/v7/extra"

run_test "inputs_platform=linux/arm/v7 is accepted" 0 \
	inputs_platform="linux/arm/v7"

#─────────────────────────────────────────────────────
section "Package Name Validation"
#─────────────────────────────────────────────────────

run_test "package name with semicolon exits 1" 1 \
	inputs_additional_apps="pkg;rm"

run_test "package name with exclamation exits 1" 1 \
	inputs_additional_apps="curl!bad"

run_test "package name starting with hyphen (flag injection) exits 1" 1 \
	inputs_additional_apps="--allow-untrusted"

run_test "valid package list is accepted" 0 \
	inputs_additional_apps="curl wget g++ libstdc++-dev python3.12"

#─────────────────────────────────────────────────────
section "Dockerfile Fast-Path"
#─────────────────────────────────────────────────────

run_test "path traversal in inputs_dockerfile exits 1" 1 \
	inputs_dockerfile="../../etc/passwd"

run_test "http remote Dockerfile exits 1" 1 \
	inputs_dockerfile="http://evil.example.com/Dockerfile"

run_test "https remote Dockerfile exits 1" 1 \
	inputs_dockerfile="https://evil.example.com/Dockerfile"

run_test "file:// URI Dockerfile exits 1" 1 \
	inputs_dockerfile="file:///etc/passwd"

run_test "missing Dockerfile exits 1" 1 \
	inputs_dockerfile="does_not_exist.txt"

_ws_df="${tmp_dir}/ws_df"
mkdir -p "$_ws_df"
printf 'FROM alpine:edge\nWORKDIR /build\n' > "${_ws_df}/my.Dockerfile"

run_test "valid Dockerfile exits 0" 0 \
	--workspace "$_ws_df" \
	inputs_dockerfile="my.Dockerfile"

invoke_script --workspace "$_ws_df" inputs_dockerfile="my.Dockerfile"
assert_gh_output "Dockerfile WORKDIR written to wd output" "wd=/build"

_ws_empty="${tmp_dir}/ws_empty"
mkdir -p "$_ws_empty"
: > "${_ws_empty}/empty.Dockerfile"
run_test "empty Dockerfile exits 1" 1 \
	--workspace "$_ws_empty" \
	inputs_dockerfile="empty.Dockerfile"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "empty Dockerfile cleans up temp Dockerfile"
if [[ ! -f "${_ws_empty}/qbt_builder_dockerfile" ]]; then
	_pass
else
	_fail "temp Dockerfile left behind on empty Dockerfile failure" ""
fi

# Filename containing consecutive dots (not a '..' path segment) must be allowed
printf 'FROM alpine:edge\n' > "${_ws_df}/my..Dockerfile"
run_test "Dockerfile filename with consecutive dots is accepted" 0 \
	--workspace "$_ws_df" \
	inputs_dockerfile="my..Dockerfile"

# Symlinked Dockerfile pointing outside workspace must be blocked without leaking target content
printf 'TOP_SECRET_HOST_TOKEN=xyz987\n' > "${tmp_dir}/secret_target"
ln -sf "${tmp_dir}/secret_target" "${_ws_df}/symlink.Dockerfile"
run_test "symlinked inputs_dockerfile exits 1" 1 \
	--workspace "$_ws_df" \
	inputs_dockerfile="symlink.Dockerfile"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "symlinked Dockerfile does not leak target content"
if ! grep -qF "TOP_SECRET_HOST_TOKEN" "${tmp_dir}/last_output" 2> /dev/null \
	&& ! grep -qF "TOP_SECRET_HOST_TOKEN" "${tmp_dir}/gh_summary" 2> /dev/null; then
	_pass
else
	_fail "symlink target content leaked to output or step summary" "$(last_output)"
fi

# Symlinked parent directory inside workspace must be blocked
mkdir -p "${tmp_dir}/outside_dir"
printf 'FROM alpine:edge\n' > "${tmp_dir}/outside_dir/Dockerfile"
ln -sfn "${tmp_dir}/outside_dir" "${_ws_df}/sym_sub"
run_test "inputs_dockerfile inside symlinked subdirectory exits 1" 1 \
	--workspace "$_ws_df" \
	inputs_dockerfile="sym_sub/Dockerfile"

#─────────────────────────────────────────────────────
section "Platform Auto-Detection from RUNNER_ARCH"
#─────────────────────────────────────────────────────

reset_docker_log
invoke_script RUNNER_ARCH="X64"
assert_docker "RUNNER_ARCH=X64 -> linux/amd64" "linux/amd64"

invoke_script RUNNER_ARCH="ARM64"
assert_docker "RUNNER_ARCH=ARM64 -> linux/arm64" "linux/arm64"

invoke_script RUNNER_ARCH="ARM"
assert_docker "RUNNER_ARCH=ARM -> linux/arm/v7" "linux/arm/v7"

invoke_script RUNNER_ARCH="X86"
assert_docker "RUNNER_ARCH=X86 -> linux/i386" "linux/i386"

#─────────────────────────────────────────────────────
section "Arch-Prefix Image Names"
#─────────────────────────────────────────────────────

reset_docker_log
invoke_script inputs_os_id="arm64v8/alpine"
assert_docker "arm64v8/alpine -> linux/arm64" "linux/arm64"

invoke_script inputs_os_id="arm32v6/alpine"
assert_docker "arm32v6/alpine -> linux/arm/v6" "linux/arm/v6"

invoke_script inputs_os_id="amd64/debian"
assert_docker "amd64/debian -> linux/amd64" "linux/amd64"

invoke_script inputs_os_id="ppc64le/alpine"
assert_docker "ppc64le/alpine -> linux/ppc64le" "linux/ppc64le"

invoke_script inputs_os_id="arm32v7/alpine"
assert_docker "arm32v7/alpine -> linux/arm/v7" "linux/arm/v7"

invoke_script inputs_os_id="s390x/alpine"
assert_docker "s390x/alpine -> linux/s390x" "linux/s390x"

invoke_script inputs_os_id="riscv64/alpine"
assert_docker "riscv64/alpine -> linux/riscv64" "linux/riscv64"

invoke_script inputs_os_id="i386/alpine"
assert_docker "i386/alpine -> linux/i386" "linux/i386"

#─────────────────────────────────────────────────────
section "GitHub Outputs"
#─────────────────────────────────────────────────────

invoke_script
assert_gh_output "container_name=qbt_builder in GITHUB_OUTPUT" "container_name=qbt_builder"

invoke_script
assert_gh_output "wd=/home/gh in GITHUB_OUTPUT" "wd=/home/gh"

invoke_script inputs_use_root="false"
assert_gh_output "inputs_use_root=false -> uid=1001" "uid=1001"

invoke_script inputs_use_root="true"
assert_gh_output "inputs_use_root=true -> uid=0" "uid=0"

# GITHUB_ENV must also carry container_name and wd
invoke_script
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "container_name written to GITHUB_ENV"
if grep -qF "container_name=qbt_builder" "${tmp_dir}/gh_env" 2> /dev/null; then
	_pass
else _fail "container_name=qbt_builder missing from GITHUB_ENV" "$(cat "${tmp_dir}/gh_env" 2> /dev/null)"; fi

invoke_script
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "wd written to GITHUB_ENV"
if grep -qF "wd=/home/gh" "${tmp_dir}/gh_env" 2> /dev/null; then
	_pass
else _fail "wd=/home/gh missing from GITHUB_ENV" "$(cat "${tmp_dir}/gh_env" 2> /dev/null)"; fi

#─────────────────────────────────────────────────────
section "OS Detection -> Dockerfile Content"
#─────────────────────────────────────────────────────

invoke_script inputs_os_id="alpine" inputs_os_version_id="edge"
assert_dockerfile "alpine image -> Dockerfile uses apk" "apk"

invoke_script inputs_os_id="debian" inputs_os_version_id="bookworm"
assert_dockerfile "debian image -> Dockerfile uses apt-get" "apt-get"

invoke_script inputs_os_id="ubuntu" inputs_os_version_id="22.04"
assert_dockerfile "ubuntu image -> Dockerfile uses apt-get" "apt-get"

invoke_script inputs_os_id="alpine"
assert_dockerfile "standard alpine -> non-root user created" "adduser"

invoke_script inputs_os_id="ghcr.io/userdocs/qbittorrent-nox" inputs_os_version_id="amd64"
assert_not_dockerfile "userdocs image -> no user creation" "adduser|useradd"

invoke_script inputs_os_id="fedora" inputs_os_version_id="40"
assert_dockerfile "unknown OS -> fallback Dockerfile generated" "if command -v apt-get"
assert_dockerfile "unknown OS -> groups user/group fallback commands safely" "\{ groupadd -g 1001 gh"
assert_dockerfile "unknown OS -> apk fallback installs sudo and bash" "apk add --no-cache sudo bash"

# Org-prefixed images (e.g., alpine/git, ubuntu/squid) must not lose their OS namespace in fallback
invoke_script inputs_os_id="alpine/git" inputs_os_version_id="latest"
assert_dockerfile "alpine/git org image -> detected as alpine (apk)" "apk add --no-cache sudo bash"

invoke_script inputs_os_id="ubuntu/squid" inputs_os_version_id="latest"
assert_dockerfile "ubuntu/squid org image -> detected as ubuntu (apt-get)" "apt-get install -y sudo"

#─────────────────────────────────────────────────────
section "OS Detection via Buildx Metadata (jq)"
#─────────────────────────────────────────────────────

# Section 1: userdocs base.id (multi-arch schema, OS-neutral image name so fallback cannot mask jq)
invoke_script \
	inputs_os_id="ghcr.io/userdocs/qbt-nox" \
	inputs_os_version_id="latest" \
	inputs_additional_apps="git" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.base.id":"Debian"}}}}}'
assert_dockerfile "userdocs base.id=Debian (multi-arch, neutral name) -> apt-get with apps" "apt-get install -y git"

# Section 1: userdocs base.name (single-arch schema, OS-neutral image name)
invoke_script \
	inputs_os_id="ghcr.io/userdocs/qbt-custom" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"image":{"config":{"Labels":{"org.opencontainers.image.base.name":"ghcr.io/library/ubuntu:24.04"}}}}'
assert_dockerfile "userdocs base.name=ubuntu (single-arch, neutral name) -> apt-get" "apt-get update"

# Section 2: official image URL label (OS-neutral image name)
invoke_script \
	inputs_os_id="custom/myimage" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.url":"https://hub.docker.com/_/debian"}}}}}'
assert_dockerfile "official image.url=debian (neutral name) -> apt-get" "apt-get"

# Section 2: Docker Hub normalized .name (docker.io/library/debian:bookworm)
invoke_script \
	inputs_os_id="custom/mystery" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"name":"docker.io/library/debian:bookworm","image":{"linux/amd64":{"config":{"Labels":{}}}}}'
assert_dockerfile "official docker.io/library/debian .name -> apt-get" "apt-get"

# Section 2: official image name fallback when .name is absent from buildx JSON
invoke_script \
	inputs_os_id="arm64v8/ubuntu" \
	inputs_os_version_id="24.04" \
	MOCK_BUILDX_JSON='{"image":{"linux/arm64":{"config":{"Labels":{}}}}}'
assert_dockerfile "official arch-prefixed name fallback when .name missing -> apt-get" "apt-get"

# Section 3: history fallback with capitalized OS name
invoke_script \
	inputs_os_id="custom/mystery" \
	inputs_os_version_id="1.0" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{}},"history":[{"created_by":"Debian base image setup"}]}}}'
assert_dockerfile "history with capitalized 'Debian' -> apt-get" "apt-get"

# Section 3: DEBIAN_FRONTEND in history must NOT falsely classify an unknown image as debian
invoke_script \
	inputs_os_id="custom/mystery" \
	inputs_os_version_id="1.0" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{}},"history":[{"created_by":"ENV DEBIAN_FRONTEND=noninteractive"}]}}}'
assert_dockerfile "DEBIAN_FRONTEND in history does not false-match debian" "if command -v apt-get"

# Multi-arch Buildx JSON with leading empty attestation entry still finds platform Labels
invoke_script \
	inputs_os_id="ghcr.io/userdocs/qbt-nox" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"image":{"attestation-manifest":{},"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.base.id":"debian"}}}}}'
assert_dockerfile "multi-arch Buildx JSON skips empty attestation entry -> apt-get" "apt-get update"

# Userdocs base.name with port-qualified registry and @sha256 digest extracts OS accurately
invoke_script \
	inputs_os_id="ghcr.io/userdocs/qbt-nox" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"image":{"config":{"Labels":{"org.opencontainers.image.base.name":"registry.local:5000/library/ubuntu@sha256:deadbeef"}}}}'
assert_dockerfile "userdocs base.name with registry:port and @sha256 -> apt-get" "apt-get update"

# Official .name pinned by @sha256 digest extracts OS accurately
invoke_script \
	inputs_os_id="custom/mystery" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"name":"docker.io/library/debian@sha256:deadbeef","image":{"config":{"Labels":{}}}}'
assert_dockerfile "official .name with @sha256 digest -> apt-get" "apt-get"

# Multi-arch Buildx JSON selects target $inputs_platform manifest when platforms differ
invoke_script \
	inputs_os_id="ghcr.io/userdocs/qbt-nox" \
	inputs_os_version_id="latest" \
	inputs_platform="linux/arm64" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.base.id":"alpine"}}},"linux/arm64":{"config":{"Labels":{"org.opencontainers.image.base.id":"debian"}}}}}'
assert_dockerfile "multi-arch Buildx JSON selects matching inputs_platform (linux/arm64 -> debian)" "apt-get update"

# Multi-arch Buildx JSON maps linux/arm64 (RUNNER_ARCH=ARM64) to linux/arm64/v8 OCI variant manifest
invoke_script \
	RUNNER_ARCH="ARM64" \
	inputs_os_id="ghcr.io/userdocs/qbt-nox" \
	inputs_os_version_id="latest" \
	MOCK_BUILDX_JSON='{"image":{"linux/amd64":{"config":{"Labels":{"org.opencontainers.image.base.id":"alpine"}}},"linux/arm64/v8":{"config":{"Labels":{"org.opencontainers.image.base.id":"debian"}}}}}'
assert_dockerfile "multi-arch Buildx JSON maps linux/arm64 to linux/arm64/v8 manifest" "apt-get update"

#─────────────────────────────────────────────────────
section "Additional Apps in Dockerfile"
#─────────────────────────────────────────────────────

invoke_script inputs_os_id="alpine" inputs_additional_apps="curl wget"
assert_dockerfile "alpine + curl wget -> curl and wget in Dockerfile" "curl wget"

invoke_script inputs_os_id="debian" inputs_os_version_id="bookworm" inputs_additional_apps="git"
assert_dockerfile "debian + git -> git in Dockerfile" "git"

# Newline-separated apps (YAML literal block | format)
invoke_script inputs_os_id="alpine" inputs_additional_apps="$(printf 'curl\nwget\n')"
assert_dockerfile "newline-separated apps -> both in Dockerfile" "curl wget"

# Userdocs Alpine with additional apps
invoke_script inputs_os_id="ghcr.io/userdocs/qbittorrent-nox" inputs_additional_apps="jq"
assert_dockerfile "userdocs alpine + jq -> apk add --no-cache jq" "apk add --no-cache jq"

#─────────────────────────────────────────────────────
section "Environment Processing"
#─────────────────────────────────────────────────────

_ws_env="${tmp_dir}/ws_env"
mkdir -p "$_ws_env"

# Safe custom env var should reach docker run via --env-file
printf 'MY_SAFE_VAR=hello\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
assert_docker "safe env.custom var passed via --env-file" "--env-file"

# PATH= in env.custom must be blocked
printf 'PATH=/evil\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
_rc=$?
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "PATH= in env.custom is blocked"
if [[ $_rc -eq 0 && -f "${_ws_env}/env.load" ]] && ! grep -q "PATH=/evil" "${_ws_env}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.load missing or contained PATH=/evil (rc=$_rc)" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# LD_PRELOAD= in env.custom must be blocked
printf 'LD_PRELOAD=evil.so\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
_rc=$?
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "LD_PRELOAD= in env.custom is blocked"
if [[ $_rc -eq 0 && -f "${_ws_env}/env.load" ]] && ! grep -q "LD_PRELOAD" "${_ws_env}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.load missing or contained LD_PRELOAD (rc=$_rc)" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# Whitespace-only lines in env.custom must be skipped without false security error messages
printf '   \n\t\t\nCLEAN_VAR=1\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
_rc=$?
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "whitespace-only lines in env.custom skipped without error"
if [[ $_rc -eq 0 ]] \
	&& grep -qx 'CLEAN_VAR=1' "${_ws_env}/env.load" 2> /dev/null \
	&& ! grep -qF "Invalid environment variable blocked" "${tmp_dir}/last_output"; then
	_pass
else
	_fail "whitespace-only line triggered false error or missing var" "$(last_output)"
fi

# Extended blocklist: BASH_ENV, ENV, PROMPT_COMMAND, GITHUB_ENV, GITHUB_STATE, DYLD_INSERT_LIBRARIES, GLIBC_TUNABLES, GCONV_PATH, SHELLOPTS, BASHOPTS must be blocked
printf 'BASH_ENV=/evil\nENV=/evil\nPROMPT_COMMAND=evil\nGITHUB_ENV=/evil\nGITHUB_STATE=/evil\nDYLD_INSERT_LIBRARIES=evil.dylib\nGLIBC_TUNABLES=glibc.malloc.check=3\nGCONV_PATH=/evil\nSHELLOPTS=xtrace\nBASHOPTS=extdebug\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "extended blocklist vars in env.custom are blocked"
if [[ -f "${_ws_env}/env.load" && ! -s "${_ws_env}/env.load" ]]; then
	_pass
else
	_fail "env.load should exist and be empty for blocked vars" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# CRLF line endings and missing trailing newline in env.custom are handled cleanly
printf 'CRLF_VAR_ONE=alpha\r\n\r\nCRLF_VAR_TWO=beta' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "CRLF and missing final newline in env.custom preserved without CR"
if [[ $(wc -l < "${_ws_env}/env.load") -eq 2 ]] \
	&& grep -qx 'CRLF_VAR_ONE=alpha' "${_ws_env}/env.load" \
	&& grep -qx 'CRLF_VAR_TWO=beta' "${_ws_env}/env.load" \
	&& ! grep -q $'\r' "${_ws_env}/env.load"; then
	_pass
else
	_fail "CRLF or missing trailing newline handling failed" "$(cat -v "${_ws_env}/env.load" 2> /dev/null)"
fi

# Blocked env var error redacts value so secrets are never printed to logs
printf 'SECRET_CONN_URL=postgres://u:super_secret_pw@db/app?a=1&b=2\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "blocked env error redacts secret value in logs"
if grep -qF "SECRET_CONN_URL=<redacted>" "${tmp_dir}/last_output" \
	&& ! grep -qF "super_secret_pw" "${tmp_dir}/last_output"; then
	_pass
else
	_fail "secret value leaked or redaction missing in output" "$(last_output)"
fi

# Symlinked env.custom must be rejected without leaking target content
_ws_sym_env="${tmp_dir}/ws_sym_env"
mkdir -p "$_ws_sym_env"
ln -sf "${tmp_dir}/secret_target" "${_ws_sym_env}/env.custom"
run_test "symlinked env.custom exits 1" 1 \
	--workspace "$_ws_sym_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "symlinked env.custom does not leak target content"
if ! grep -qF "TOP_SECRET_HOST_TOKEN" "${tmp_dir}/last_output" 2> /dev/null; then
	_pass
else
	_fail "symlinked env.custom leaked target content" "$(last_output)"
fi

# Dangerous characters in env.custom value must be blocked
# shellcheck disable=SC2016
printf 'BAD_SEMI=foo;bar\nBAD_CMD=$(id)\n# comment line\n\nGOOD_VAR=ok\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "dangerous chars and comments filtered, valid var kept in env.load"
if grep -q "^GOOD_VAR=ok$" "${_ws_env}/env.load" 2> /dev/null && ! grep -qE "BAD_SEMI|BAD_CMD" "${_ws_env}/env.load" 2> /dev/null; then
	_pass
else
	_fail "unexpected env.load contents" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# inputs_use_host_env=true should dump environment to env.host
_ws_host="${tmp_dir}/ws_host"
mkdir -p "$_ws_host"
invoke_script --workspace "$_ws_host" inputs_use_host_env="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_host_env=true creates env.host"
if [[ -f "${_ws_host}/env.host" ]]; then
	_pass
else _fail "env.host was not created" "$(last_output)"; fi

# inputs_use_host_env=true succeeds when final env -0 entry contains newlines
_ws_host_ml="${tmp_dir}/ws_host_ml"
mkdir -p "$_ws_host_ml"
invoke_script \
	--workspace "$_ws_host_ml" \
	inputs_use_host_env="true" \
	inputs_additional_apps=$'curl\nwget' \
	ZZZ_TRAILING_MULTILINE=$'line1\nline2'
_rc=$?
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_host_env=true succeeds when trailing env var is multiline"
if [[ $_rc -eq 0 && -s "${_ws_host_ml}/env.host" ]] \
	&& ! grep -qF "ZZZ_TRAILING_MULTILINE" "${_ws_host_ml}/env.host" 2> /dev/null; then
	_pass
else
	_fail "multiline trailing env var caused host env dump failure (rc=$_rc)" "$(last_output)"
fi

# Combined inputs_use_host_env=true + env.custom merges both and removes .safe intermediates
_ws_both="${tmp_dir}/ws_both"
mkdir -p "$_ws_both"
printf 'CUSTOM_MERGED_VAR=42\n' > "${_ws_both}/env.custom"
invoke_script --workspace "$_ws_both" inputs_use_host_env="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "host + custom merges into env.load and removes .safe temp files"
if grep -q "CUSTOM_MERGED_VAR=42" "${_ws_both}/env.load" 2> /dev/null \
	&& grep -q "RUNNER_ARCH=X64" "${_ws_both}/env.load" 2> /dev/null \
	&& [[ ! -f "${_ws_both}/env.host.safe" && ! -f "${_ws_both}/env.custom.safe" ]]; then
	_pass
else
	_fail "host + custom merge or cleanup failed" "$(cat "${_ws_both}/env.load" 2> /dev/null)"
fi

# env.host from workspace should be ignored if inputs_use_host_env=false
_ws_host_ignore="${tmp_dir}/ws_host_ignore"
mkdir -p "$_ws_host_ignore"
printf 'EVIL_VAR=bad\n' > "${_ws_host_ignore}/env.host"
invoke_script --workspace "$_ws_host_ignore" inputs_use_host_env="false"
_rc=$?
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "env.host ignored when inputs_use_host_env=false"
if [[ $_rc -eq 0 ]] && ! grep -q "EVIL_VAR" "${_ws_host_ignore}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.host was loaded even though inputs_use_host_env=false (rc=$_rc)" "$(cat "${_ws_host_ignore}/env.load" 2> /dev/null)"
fi

# Pre-existing symlink at env.host must be unlinked (target not clobbered) and env files set to 0600
_ws_host_sym="${tmp_dir}/ws_host_sym"
mkdir -p "$_ws_host_sym"
printf 'DO_NOT_CLOBBER\n' > "${tmp_dir}/protected_host_target"
ln -sf "${tmp_dir}/protected_host_target" "${_ws_host_sym}/env.host"
invoke_script --workspace "$_ws_host_sym" inputs_use_host_env="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "pre-existing env.host symlink unlinked without clobbering target and mode is 600"
_env_host_perm=$(stat -c '%a' "${_ws_host_sym}/env.host" 2> /dev/null)
if [[ $(cat "${tmp_dir}/protected_host_target") == "DO_NOT_CLOBBER" ]] \
	&& [[ ! -L "${_ws_host_sym}/env.host" ]] \
	&& [[ $_env_host_perm == "600" ]]; then
	_pass
else
	_fail "env.host symlink clobbered target or permissions ($_env_host_perm) != 600" ""
fi

# Failed input validation must not dump env.host when inputs_use_host_env=true
_ws_no_dump="${tmp_dir}/ws_no_dump"
mkdir -p "$_ws_no_dump"
run_test "invalid input with inputs_use_host_env=true exits 1" 1 \
	--workspace "$_ws_no_dump" \
	inputs_use_host_env="true" \
	inputs_custom_docker_commands="--rm"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "failed validation does not dump env.host into workspace"
if [[ ! -e "${_ws_no_dump}/env.host" && ! -e "${_ws_no_dump}/env.load" ]]; then
	_pass
else
	_fail "env.host or env.load created before input validation completed" ""
fi

# Pre-existing stale env.load must not be loaded when use_host=false and env.custom is absent
_ws_stale="${tmp_dir}/ws_stale"
mkdir -p "$_ws_stale"
printf 'LD_PRELOAD=/evil.so\n' > "${_ws_stale}/env.load"
invoke_script --workspace "$_ws_stale" inputs_use_host_env="false"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "pre-existing stale env.load is removed when no env sources active"
if [[ ! -f "${_ws_stale}/env.load" ]] && ! grep -qF -- "--env-file" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
	_pass
else
	_fail "stale env.load was not removed or was passed to docker" "$(docker_log)"
fi

# Directory collision at env.load or env.custom fails upfront before docker build
_ws_dir_envload="${tmp_dir}/ws_dir_envload"
mkdir -p "${_ws_dir_envload}/env.load"
run_test "directory collision at env.load exits 1" 1 \
	--workspace "$_ws_dir_envload"

_ws_dir_envcustom="${tmp_dir}/ws_dir_envcustom"
mkdir -p "${_ws_dir_envcustom}/env.custom"
run_test "directory at env.custom exits 1" 1 \
	--workspace "$_ws_dir_envcustom"

#─────────────────────────────────────────────────────
section "Custom Docker Commands"
#─────────────────────────────────────────────────────

invoke_script inputs_custom_docker_commands="--volume /tmp:/tmp"
assert_docker "--volume arg passed to docker run" "/tmp:/tmp"

invoke_script inputs_custom_docker_commands="--env MY_VAR=hello"
assert_docker "--env MY_VAR=value passed to docker run" "MY_VAR=hello"

invoke_script inputs_custom_docker_commands="$(printf -- '-e SHORT_VAR=1\n--memory 2g\n--cpus 2\n')"
assert_docker "short and resource flags passed to docker run" "-e SHORT_VAR=1 --memory 2g --cpus 2"

run_test "unrecognised docker arg exits 1" 1 \
	inputs_custom_docker_commands="--rm"

assert_output "invalid docker arg produces security message" "Security" \
	inputs_custom_docker_commands="--rm"

run_test "bare docker arg without value exits 1" 1 \
	inputs_custom_docker_commands="--env"

# Command substitution in a value must be blocked
run_test "command substitution in docker command value exits 1" 1 \
	inputs_custom_docker_commands="--env FOO=\$(cat /etc/passwd)"

# Unsafe variable expansions starting with 'w' ($workspace, ${workspace}, $wd_extra) must be blocked
# shellcheck disable=SC2016
run_test '$workspace expansion in docker command value exits 1' 1 \
	inputs_custom_docker_commands='--volume $workspace:/host'

# shellcheck disable=SC2016
run_test '${workspace} expansion in docker command value exits 1' 1 \
	inputs_custom_docker_commands='--volume ${workspace}:/host'

# shellcheck disable=SC2016
run_test '$wd_extra prefix variable in docker command value exits 1' 1 \
	inputs_custom_docker_commands='--volume $wd_extra:/host'

# $wd and ${wd} variables are expanded to /home/gh in a volume value.
# Single quotes are intentional: $wd must reach the script unexpanded.
# shellcheck disable=SC2016
invoke_script inputs_custom_docker_commands='--volume $wd:/host'
# shellcheck disable=SC2016
assert_docker '$wd expanded to /home/gh in volume arg' "/home/gh:/host"

# shellcheck disable=SC2016
invoke_script inputs_custom_docker_commands='--volume ${wd}/sub:/host'
# shellcheck disable=SC2016
assert_docker '${wd} expanded to /home/gh in volume arg' "/home/gh/sub:/host"

# Valid user, workdir, read-only volume, and fractional cpus flags accepted
invoke_script inputs_custom_docker_commands="$(printf -- '-u 1001:1001\n-w /opt/work\n--volume /tmp:/tmp:ro\n--cpus 1.5\n')"
assert_docker "valid -u, -w, :ro volume, and decimal --cpus passed to docker run" "-u 1001:1001 -w /opt/work --volume /tmp:/tmp:ro --cpus 1.5"

# Blocked env vars in --env / -e must exit 1 (cannot bypass check_env_var)
run_test "--env LD_PRELOAD in custom docker commands exits 1" 1 \
	inputs_custom_docker_commands="--env LD_PRELOAD=/evil.so"

run_test "-e PATH in custom docker commands exits 1" 1 \
	inputs_custom_docker_commands="-e PATH=/evil"

# Valueless -e VAR (host env inheritance bypass) must exit 1
run_test "valueless -e VAR in custom docker commands exits 1" 1 \
	inputs_custom_docker_commands="-e HOME"

# Docker socket mount and smuggled extra flags on one line must exit 1
run_test "docker.sock mount in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /var/run/docker.sock:/var/run/docker.sock"

run_test "docker.sock/ trailing-slash mount in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /var/run/docker.sock/:/tmp/sock"

run_test "host root filesystem mount (/:/host) in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /:/host"

run_test "single-dot host root filesystem mount (/.:/host) in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /.:/host"

run_test "slash-dot-slash host rootfs mount (/./:/host) in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /./:/host"

run_test "container root mount with options (/tmp:/:ro) in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /tmp:/:ro"

run_test "valid hidden dot-directory mount (/tmp/.cache:/app/.cache:ro) is accepted" 0 \
	inputs_custom_docker_commands="--volume /tmp/.cache:/app/.cache:ro"

run_test "relative container mount destination in --volume exits 1" 1 \
	inputs_custom_docker_commands="--volume /tmp:relative_dest"

# Secret value in --env reaches docker run while redacted in step summary and error logs
invoke_script inputs_custom_docker_commands="--env MY_API_SECRET=ultra_secret_token_777"
assert_docker "--env secret passed to docker run" "--env MY_API_SECRET=ultra_secret_token_777"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "--env secret value redacted in stdout and GITHUB_STEP_SUMMARY"
if grep -qF "MY_API_SECRET=<redacted>" "${tmp_dir}/gh_summary" \
	&& ! grep -qF "ultra_secret_token_777" "${tmp_dir}/gh_summary" \
	&& ! grep -qF "ultra_secret_token_777" "${tmp_dir}/last_output"; then
	_pass
else
	_fail "--env secret value leaked to summary or stdout" "$(last_output)"
fi

invoke_script MOCK_DOCKER_FAIL="run" inputs_custom_docker_commands="-e MY_API_SECRET=ultra_secret_token_777"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "-e secret value redacted in docker run error log"
if grep -qF "MY_API_SECRET=<redacted>" "${tmp_dir}/last_output" \
	&& ! grep -qF "ultra_secret_token_777" "${tmp_dir}/last_output"; then
	_pass
else
	_fail "-e secret value leaked on docker run failure" "$(last_output)"
fi

# --env value containing unsafe $var is blocked AND its secret value is redacted on stderr
# shellcheck disable=SC2016
run_test '--env secret containing unsafe $ expansion exits 1' 1 \
	inputs_custom_docker_commands='--env DB_PASS=top_secret_pw$bad'
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" '--env blocked $ expansion redacts secret value in error output'
if grep -qF "DB_PASS=<redacted>" "${tmp_dir}/last_output" \
	&& ! grep -qF "top_secret_pw" "${tmp_dir}/last_output"; then
	_pass
else
	_fail '--env $ expansion error leaked plaintext secret' "$(last_output)"
fi

# --env=KEY=VAL inline syntax exits 1 and redacts secret value in error output
run_test "--env=KEY=VAL inline syntax exits 1" 1 \
	inputs_custom_docker_commands="--env=MY_INLINE_SECRET=top_secret_inline_999"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "--env=KEY=VAL blocked arg redacts secret value in error output"
if grep -qF -- "--env=<redacted>" "${tmp_dir}/last_output" \
	&& ! grep -qF "top_secret_inline_999" "${tmp_dir}/last_output"; then
	_pass
else
	_fail "--env=KEY=VAL error leaked plaintext secret" "$(last_output)"
fi

run_test "extra flag smuggled on --volume line exits 1" 1 \
	inputs_custom_docker_commands="--volume /tmp:/tmp --privileged"

run_test "path traversal in --workdir exits 1" 1 \
	inputs_custom_docker_commands="--workdir /app/../../etc"

run_test "zero --memory value exits 1" 1 \
	inputs_custom_docker_commands="--memory 0"

run_test "zero --cpus value exits 1" 1 \
	inputs_custom_docker_commands="--cpus 0"

#─────────────────────────────────────────────────────
section "Security Hardening & Platform Precedence"
#─────────────────────────────────────────────────────

# Explicit inputs_platform overrides RUNNER_ARCH
invoke_script RUNNER_ARCH="X64" inputs_platform="linux/arm64"
assert_docker "explicit inputs_platform overrides RUNNER_ARCH" "linux/arm64"

# Explicit inputs_platform is preserved even with arch-prefixed inputs_os_id
invoke_script inputs_os_id="arm64v8/alpine" inputs_platform="linux/arm64/v8"
assert_docker "explicit inputs_platform preserved with arch-prefixed os_id" "linux/arm64/v8"

# Invalid inputs_platform still fails even with arch-prefixed inputs_os_id
run_test "invalid inputs_platform with arch-prefixed os_id exits 1" 1 \
	inputs_os_id="arm64v8/alpine" \
	inputs_platform="INVALID_PLATFORM"

# Unknown RUNNER_ARCH falls back to linux/amd64
invoke_script RUNNER_ARCH="SPARC64"
assert_docker "unknown RUNNER_ARCH falls back to linux/amd64" "linux/amd64"

# --platform must appear exactly once in the docker run call (no duplicate)
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "--platform not duplicated in docker run"
invoke_script
run_line=$(grep "^run " "${tmp_dir}/docker_calls.log" 2> /dev/null | head -1)
count=$(printf '%s' "$run_line" | grep -o -- "--platform" | wc -l)
if [[ $count -eq 1 ]]; then
	_pass
else _fail "--platform appeared $count times in: $run_line" ""; fi

# --cap-drop ALL present in standard docker run
invoke_script
assert_docker "standard docker run has --cap-drop ALL" "--cap-drop ALL"

# -u present when inputs_use_root=false
invoke_script inputs_use_root="false"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_root=false -> -u 1001:1001 in docker run"
if grep -qF -- "-u 1001:1001" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
	_pass
else _fail "-u 1001:1001 not found in docker run" "$(docker_log)"; fi

# No -u when inputs_use_root=true
invoke_script inputs_use_root="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_root=true -> no -u flag in docker run"
if grep -q "^run " "${tmp_dir}/docker_calls.log" 2> /dev/null \
	&& ! grep -qF -- "-u 1001" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
	_pass
else _fail "-u 1001 should not appear in docker run (or docker run did not execute)" "$(docker_log)"; fi

# Workspace volume mount present
invoke_script
assert_docker "workspace volume mounted into container" ":/home/gh"

#─────────────────────────────────────────────────────
section "Fast-Path WORKDIR & Docker Error Handling"
#─────────────────────────────────────────────────────

# Custom Dockerfile WORKDIR expands $wd in inputs_custom_docker_commands
# shellcheck disable=SC2016
invoke_script \
	--workspace "$_ws_df" \
	inputs_dockerfile="my.Dockerfile" \
	inputs_custom_docker_commands='--volume $wd:/host'
# shellcheck disable=SC2016
assert_docker 'fast-path $wd in custom command uses Dockerfile WORKDIR' "/build:/host"

# Quoted WORKDIR with trailing whitespace is parsed cleanly
printf 'FROM alpine:edge\nWORKDIR "/opt/app"   \r\n' > "${_ws_df}/quoted.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="quoted.Dockerfile"
assert_gh_output "quoted WORKDIR parsed cleanly" "wd=/opt/app"

# Invalid WORKDIR logs warning and retains default /home/gh
printf 'FROM alpine:edge\nWORKDIR /bad;path\n' > "${_ws_df}/badwd.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="badwd.Dockerfile"
assert_gh_output "invalid WORKDIR retains default wd=/home/gh" "wd=/home/gh"

# Path-traversing WORKDIR logs warning and retains default /home/gh
printf 'FROM alpine:edge\nWORKDIR /app/../../etc\n' > "${_ws_df}/travwd.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="travwd.Dockerfile"
assert_gh_output "path-traversing WORKDIR retains default wd=/home/gh" "wd=/home/gh"

# Sequential relative WORKDIR resolves against prior WORKDIR in stage
printf 'FROM alpine:edge\nWORKDIR /opt\nWORKDIR app\n' > "${_ws_df}/relwd.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="relwd.Dockerfile"
assert_gh_output "sequential relative WORKDIR resolves to /opt/app" "wd=/opt/app"

# Dot segments in WORKDIR (/opt/./app and WORKDIR .) normalize cleanly
printf 'FROM alpine:edge\nWORKDIR /opt/./app\nWORKDIR .\n' > "${_ws_df}/dotwd.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="dotwd.Dockerfile"
assert_gh_output "dot segments in WORKDIR normalize to /opt/app" "wd=/opt/app"

# Fast-path WORKDIR / with $wd:/host fails validation cleanly without leaving temp Dockerfile behind
_ws_rootwd="${tmp_dir}/ws_rootwd"
mkdir -p "$_ws_rootwd"
printf 'FROM alpine:edge\nWORKDIR .\n' > "${_ws_rootwd}/root.Dockerfile"
# shellcheck disable=SC2016
run_test 'WORKDIR . (/) with --volume $wd:/host exits 1' 1 \
	--workspace "$_ws_rootwd" \
	inputs_dockerfile="root.Dockerfile" \
	inputs_custom_docker_commands='--volume $wd:/host'
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" 'rejected post-WORKDIR custom command leaves no temp Dockerfile'
if [[ ! -e "${_ws_rootwd}/qbt_builder_dockerfile" ]]; then
	_pass
else
	_fail "temp Dockerfile left behind after post-WORKDIR validation failure" ""
fi

# Pre-existing symlink at qbt_builder_dockerfile pointing to inputs_dockerfile is replaced and cleaned up without deleting source
_ws_sym_self="${tmp_dir}/ws_sym_self"
mkdir -p "$_ws_sym_self"
printf 'FROM alpine:edge\nWORKDIR /sym_self\n' > "${_ws_sym_self}/real.Dockerfile"
ln -sf "${_ws_sym_self}/real.Dockerfile" "${_ws_sym_self}/qbt_builder_dockerfile"
run_test "pre-existing symlink at qbt_builder_dockerfile -> real.Dockerfile succeeds" 0 \
	--workspace "$_ws_sym_self" \
	inputs_dockerfile="real.Dockerfile"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "pre-existing qbt_builder_dockerfile symlink removed while real.Dockerfile preserved"
if [[ -s "${_ws_sym_self}/real.Dockerfile" && ! -e "${_ws_sym_self}/qbt_builder_dockerfile" ]]; then
	_pass
else
	_fail "real.Dockerfile lost or symlink left behind" ""
fi

# Multi-stage Dockerfile without WORKDIR in final stage does not leak builder WORKDIR
printf 'FROM alpine:edge AS builder\nWORKDIR /tmp/stage1\nFROM alpine:edge\nRUN true\n' > "${_ws_df}/multistage_none.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="multistage_none.Dockerfile"
assert_gh_output "multi-stage without final WORKDIR retains default wd=/home/gh" "wd=/home/gh"

# Multi-stage Dockerfile with WORKDIR in final stage uses final stage WORKDIR
printf 'FROM alpine:edge AS builder\nWORKDIR /tmp/stage1\nFROM alpine:edge\nWORKDIR /srv/final\n' > "${_ws_df}/multistage_final.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="multistage_final.Dockerfile"
assert_gh_output "multi-stage with final WORKDIR uses wd=/srv/final" "wd=/srv/final"

# Multi-stage Dockerfile inheriting from earlier named stage inherits its WORKDIR
printf 'FROM alpine:edge AS base\nWORKDIR /opt/inherited\nFROM base\nRUN true\n' > "${_ws_df}/multistage_inherit.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="multistage_inherit.Dockerfile"
assert_gh_output "multi-stage FROM <alias> inherits stage WORKDIR" "wd=/opt/inherited"

# Multiline RUN with inline 'from ... import ...' and backslash continuation does not reset WORKDIR
printf 'FROM alpine:edge\nWORKDIR /workspace\nRUN echo ok \\\n  # comment inside continuation\n  from_continuation && python3 -c '\''\nfrom pathlib import Path\n'\''\n' > "${_ws_df}/multiline_run.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="multiline_run.Dockerfile"
assert_gh_output "multiline RUN with 'from ...' does not clobber WORKDIR" "wd=/workspace"

# Multiline FROM --platform=\ continuation and BuildKit <<EOF heredoc ignore heredoc WORKDIR/FROM
cat > "${_ws_df}/heredoc.Dockerfile" << 'EOF'
FROM --platform=linux/amd64 \
	alpine:edge AS stage1
WORKDIR /stage1_ignored
FROM --platform=linux/amd64 \
	alpine:edge
WORKDIR /heredoc_safe
RUN <<HEREDOC
WORKDIR /should_be_ignored
FROM scratch
HEREDOC
EOF
invoke_script --workspace "$_ws_df" inputs_dockerfile="heredoc.Dockerfile"
assert_gh_output "multiline FROM and BuildKit <<HEREDOC preserve real WORKDIR" "wd=/heredoc_safe"

# BuildKit COPY <<'EOF' with relative destination ignores heredoc WORKDIR/FROM
cat > "${_ws_df}/copy_heredoc.Dockerfile" << 'EOF'
FROM alpine:edge
WORKDIR /app_rel_copy
COPY --chmod=0755 <<'EOF_SCRIPT' entrypoint.sh
#!/bin/sh
WORKDIR /wrong_copy_wd
FROM scratch
EOF_SCRIPT
EOF
invoke_script --workspace "$_ws_df" inputs_dockerfile="copy_heredoc.Dockerfile"
assert_gh_output "BuildKit COPY <<EOF with relative destination preserves WORKDIR" "wd=/app_rel_copy"

# Bash <<< here-string and << bitshift inside RUN must NOT falsely open a BuildKit heredoc
cat > "${_ws_df}/herestring_bitshift.Dockerfile" << 'EOF'
FROM alpine:edge
RUN bash -c 'read -r x <<< "hello"'
RUN python3 -c 'shift = 2; print(1 << shift)'
WORKDIR /after_herestring
EOF
invoke_script --workspace "$_ws_df" inputs_dockerfile="herestring_bitshift.Dockerfile"
assert_gh_output "<<< here-string and << bitshift do not swallow subsequent WORKDIR" "wd=/after_herestring"

# Dangling trailing backslash at EOF still evaluates final WORKDIR instruction
printf 'FROM alpine:edge\nWORKDIR /dangling_eof \134' > "${_ws_df}/dangling.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="dangling.Dockerfile"
assert_gh_output "dangling trailing backslash at EOF preserves WORKDIR" "wd=/dangling_eof"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Dockerfile without trailing newline preserves closing code fence in GITHUB_STEP_SUMMARY"
if [[ $(grep -Fcx -- $'\x60\x60\x60' "${tmp_dir}/gh_summary" 2> /dev/null) -eq 2 ]]; then
	_pass
else
	_fail "closing Markdown code fence corrupted in GITHUB_STEP_SUMMARY" "$(cat "${tmp_dir}/gh_summary" 2> /dev/null)"
fi

# Adversarial FROM token with brackets/command-like syntax cannot trigger array subscript errors or command execution
# shellcheck disable=SC2016
printf 'FROM bad[$(touch %s/pwned)]\nWORKDIR /safe_sub\n' "${tmp_dir}" > "${_ws_df}/badsub.Dockerfile"
invoke_script --workspace "$_ws_df" inputs_dockerfile="badsub.Dockerfile"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "FROM with bracket/command syntax does not execute or fail array subscript"
if [[ ! -e "${tmp_dir}/pwned" ]] \
	&& ! grep -qi "bad array subscript" "${tmp_dir}/last_output" \
	&& grep -qF "wd=/safe_sub" "${tmp_dir}/gh_output"; then
	_pass
else
	_fail "bracketed FROM caused subscript error or command execution" "$(last_output)"
fi

# Fast-path when inputs_dockerfile is named qbt_builder_dockerfile (-ef self-preservation)
_ws_self_df="${tmp_dir}/ws_self_df"
mkdir -p "$_ws_self_df"
printf 'FROM alpine:edge\nWORKDIR /self_ok\n' > "${_ws_self_df}/qbt_builder_dockerfile"
run_test "inputs_dockerfile=qbt_builder_dockerfile succeeds" 0 \
	--workspace "$_ws_self_df" \
	inputs_dockerfile="qbt_builder_dockerfile"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "source qbt_builder_dockerfile preserved when used directly as input"
if [[ -s "${_ws_self_df}/qbt_builder_dockerfile" ]]; then
	_pass
else
	_fail "user-supplied qbt_builder_dockerfile was deleted" ""
fi

# docker build uses $workspace as build context in both fast-path and standard path
invoke_script --workspace "$_ws_df" inputs_dockerfile="my.Dockerfile"
assert_docker "fast-path docker build uses workspace as build context" "-t custom_dockerfile ${_ws_df}"
invoke_script --workspace "$_ws_df"
assert_docker "standard docker build uses workspace as build context" "-t qbt_builder ${_ws_df}"

# Standard path docker build failure exits 1, cleans up temporary Dockerfile, and does not dump env.host
_ws_fail="${tmp_dir}/ws_fail"
mkdir -p "$_ws_fail"
run_test "standard docker build failure exits 1" 1 \
	--workspace "$_ws_fail" \
	inputs_use_host_env="true" \
	MOCK_DOCKER_FAIL="build"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "standard docker build failure cleans up temp Dockerfile and skips env.host dump"
if [[ ! -f "${_ws_fail}/qbt_builder_dockerfile" && ! -e "${_ws_fail}/env.host" && ! -e "${_ws_fail}/env.load" ]]; then
	_pass
else
	_fail "temporary Dockerfile or env.host left behind after build failure" ""
fi

# Fast-path docker build failure exits 1, cleans up temporary Dockerfile, and skips env.host dump
_ws_fp_fail="${tmp_dir}/ws_fp_fail"
mkdir -p "$_ws_fp_fail"
printf 'FROM alpine:edge\nWORKDIR /build\n' > "${_ws_fp_fail}/my.Dockerfile"
run_test "fast-path docker build failure exits 1" 1 \
	--workspace "$_ws_fp_fail" \
	inputs_dockerfile="my.Dockerfile" \
	inputs_use_host_env="true" \
	MOCK_DOCKER_FAIL="build"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "fast-path docker build failure cleans up temp Dockerfile and skips env.host dump"
if [[ ! -f "${_ws_fp_fail}/qbt_builder_dockerfile" && ! -e "${_ws_fp_fail}/env.host" && ! -e "${_ws_fp_fail}/env.load" ]]; then
	_pass
else
	_fail "temporary Dockerfile or env.host left behind after fast-path build failure" ""
fi

# Standard path docker run failure exits 1
run_test "standard docker run failure exits 1" 1 \
	MOCK_DOCKER_FAIL="run"

# Fast-path docker run failure exits 1
run_test "fast-path docker run failure exits 1" 1 \
	--workspace "$_ws_df" \
	inputs_dockerfile="my.Dockerfile" \
	MOCK_DOCKER_FAIL="run"

#─────────────────────────────────────────────────────
section "Source Guard & Direct Unit Checks"
#─────────────────────────────────────────────────────

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Sourcing script does not exit the shell"
_source_guard_ok=0
(
	export GITHUB_WORKSPACE="${tmp_dir}/ws"
	export GITHUB_ENV="${tmp_dir}/gh_env"
	export GITHUB_OUTPUT="${tmp_dir}/gh_output"
	export GITHUB_STEP_SUMMARY="${tmp_dir}/gh_summary"
	# shellcheck source=/dev/null
	source "$script_path" 2> /dev/null
	exit 0
) && _source_guard_ok=1
if [[ $_source_guard_ok -eq 1 ]]; then
	_pass
else _fail "sourcing the script caused a non-zero exit" ""; fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "validate_input with unknown type exits 1"
if ! (
	# shellcheck source=/dev/null
	source "$script_path" 2> /dev/null
	validate_input "foo" "nonexistent_type" 2> /dev/null
); then
	_pass
else
	_fail "validate_input should exit 1 on unknown type" ""
fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "to_gh_env and to_gh_output reject blocked and multiline variables"
if (
	# shellcheck source=/dev/null
	source "$script_path" 2> /dev/null
	! to_gh_env "PATH=/evil" 2> /dev/null \
		&& ! to_gh_output "LD_PRELOAD=evil.so" 2> /dev/null \
		&& ! to_gh_env $'SAFE=1\nLD_PRELOAD=evil.so' 2> /dev/null \
		&& ! to_gh_output $'SAFE=1\nPATH=/evil' 2> /dev/null
); then
	_pass
else
	_fail "to_gh_env / to_gh_output should return non-zero for blocked or multiline vars" ""
fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Re-sourcing script twice in same set -e shell succeeds without errors"
_resource_err=$(
	{
		set -e
		# shellcheck source=/dev/null
		source "$script_path"
		# shellcheck source=/dev/null
		source "$script_path"
	} 2>&1
) && _resource_rc=0 || _resource_rc=$?
if [[ $_resource_rc -eq 0 && -z $_resource_err ]]; then
	_pass
else
	_fail "re-sourcing failed (rc=$_resource_rc)" "$_resource_err"
fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Execution with unset GITHUB_ENV, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY succeeds"
mkdir -p "${tmp_dir}/ws_unset_gh"
if env -i \
	HOME="${HOME:-/root}" \
	PATH="${tmp_dir}:${PATH}" \
	GITHUB_WORKSPACE="${tmp_dir}/ws_unset_gh" \
	RUNNER_ARCH="X64" \
	bash "$script_path" > "${tmp_dir}/unset_gh.out" 2>&1; then
	_pass
else
	_fail "script failed when GITHUB_* file vars were unset" "$(cat "${tmp_dir}/unset_gh.out")"
fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Execution without docker in PATH exits 1 cleanly"
mkdir -p "${tmp_dir}/no_docker_bin" "${tmp_dir}/ws_nodocker"
ln -sf "$(command -v bash)" "${tmp_dir}/no_docker_bin/bash"
if ! env -i \
	HOME="${HOME:-/root}" \
	PATH="${tmp_dir}/no_docker_bin" \
	GITHUB_WORKSPACE="${tmp_dir}/ws_nodocker" \
	RUNNER_ARCH="X64" \
	"${tmp_dir}/no_docker_bin/bash" "$script_path" > "${tmp_dir}/nodocker.out" 2>&1 \
	&& grep -qF "Docker CLI is not installed" "${tmp_dir}/nodocker.out"; then
	_pass
else
	_fail "missing docker binary did not exit 1 with expected message" "$(cat "${tmp_dir}/nodocker.out" 2> /dev/null)"
fi

printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "Sourcing and calling validation functions preserves caller LC_ALL and works under custom IFS"
if (
	# shellcheck source=/dev/null
	source "$script_path" 2> /dev/null
	LC_ALL="$_utf8_loc"
	IFS=":"
	check_env_var "GOOD_VAR=1"
	validate_input "linux/amd64" "platform"
	declare -a _apps=()
	parse_app_list "curl wget" _apps
	# shellcheck disable=SC2034
	inputs_additional_apps="curl git"
	# shellcheck disable=SC2034
	inputs_custom_docker_commands="--memory 2g"
	parse_docker_commands
	# shellcheck disable=SC2154
	[[ $LC_ALL == "$_utf8_loc" && $IFS == ":" && ${#_apps[@]} -eq 2 && ${#clean_envs[@]} -eq 2 ]]
); then
	_pass
else
	_fail "validation/parsing functions mutated caller LC_ALL/IFS or failed under custom IFS" ""
fi

#─────────────────────────────────────────────────────
# SUMMARY
#─────────────────────────────────────────────────────

total=$((pass_count + fail_count))
printf '\n\033[1m─────────────────────────────────\033[0m\n'
printf 'Total:  %d\n' "$total"
printf 'Passed: %d\n' "$pass_count"
printf 'Failed: %d\n' "$fail_count"
printf '\033[1m─────────────────────────────────\033[0m\n'

if [[ $fail_count -eq 0 ]]; then
	printf '\033[32mALL TESTS PASSED\033[0m\n'
	exit 0
else
	printf '\033[31mSOME TESTS FAILED\033[0m\n'
	exit 1
fi
