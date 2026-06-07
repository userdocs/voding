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
# Stdout+stderr go to $tmp_dir/last_output.  Resets gh env files each call.
invoke_script() {
	local ws_dir="${tmp_dir}/ws"
	local -a extra_env=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--workspace)
				ws_dir="$2"
				shift 2
				;;
			*)
				extra_env+=("$1")
				shift
				;;
		esac
	done

	mkdir -p "$ws_dir"

	: > "${tmp_dir}/gh_env"
	: > "${tmp_dir}/gh_output"
	: > "${tmp_dir}/gh_summary"

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
	if printf '%s' "$plain" | grep -q "$pattern"; then
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
	if grep -qF "$pattern" "${tmp_dir}/gh_output" 2> /dev/null; then
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
	if grep -q "$pattern" "${tmp_dir}/last_dockerfile" 2> /dev/null; then
		_pass
	else
		_fail "Dockerfile did not contain: $pattern" "$(cat "${tmp_dir}/last_dockerfile" 2> /dev/null)"
	fi
}

# Post-invoke: assert the saved Dockerfile does NOT contain a pattern.
assert_not_dockerfile() {
	local name="$1"
	local pattern="$2"
	printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "$name"
	if ! grep -q "$pattern" "${tmp_dir}/last_dockerfile" 2> /dev/null; then
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
# buildx returns empty output to trigger name-only OS fallback in detect_image_os.
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
		;;
	buildx|run|*) ;;
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

#─────────────────────────────────────────────────────
section "Platform Validation"
#─────────────────────────────────────────────────────

run_test "inputs_platform=LINUX/AMD64 (uppercase) exits 1" 1 \
	inputs_platform="LINUX/AMD64"

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

run_test "valid package list is accepted" 0 \
	inputs_additional_apps="curl wget"

#─────────────────────────────────────────────────────
section "Dockerfile Fast-Path"
#─────────────────────────────────────────────────────

run_test "path traversal in inputs_dockerfile exits 1" 1 \
	inputs_dockerfile="../../etc/passwd"

run_test "http remote Dockerfile exits 1" 1 \
	inputs_dockerfile="http://evil.example.com/Dockerfile"

run_test "https remote Dockerfile exits 1" 1 \
	inputs_dockerfile="https://evil.example.com/Dockerfile"

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
assert_not_dockerfile "userdocs image -> no user creation" "adduser\|useradd"

#─────────────────────────────────────────────────────
section "Additional Apps in Dockerfile"
#─────────────────────────────────────────────────────

invoke_script inputs_os_id="alpine" inputs_additional_apps="curl wget"
assert_dockerfile "alpine + curl wget -> curl in Dockerfile" "curl"

invoke_script inputs_os_id="debian" inputs_os_version_id="bookworm" inputs_additional_apps="git"
assert_dockerfile "debian + git -> git in Dockerfile" "git"

# Newline-separated apps (YAML literal block | format)
invoke_script inputs_os_id="alpine" inputs_additional_apps="$(printf 'curl\nwget\n')"
assert_dockerfile "newline-separated apps -> both in Dockerfile" "curl"

#─────────────────────────────────────────────────────
section "Environment Processing"
#─────────────────────────────────────────────────────

_ws_env="${tmp_dir}/ws_env"
mkdir -p "$_ws_env"

# Safe custom env var should reach docker run via --env-file
printf 'MY_SAFE_VAR=hello\n' > "${_ws_env}/env.custom"
reset_docker_log
invoke_script --workspace "$_ws_env"
assert_docker "safe env.custom var passed via --env-file" "--env-file"

# PATH= in env.custom must be blocked
printf 'PATH=/evil\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "PATH= in env.custom is blocked"
if ! grep -q "PATH=/evil" "${_ws_env}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.load should not contain PATH=/evil" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# LD_PRELOAD= in env.custom must be blocked
printf 'LD_PRELOAD=evil.so\n' > "${_ws_env}/env.custom"
invoke_script --workspace "$_ws_env"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "LD_PRELOAD= in env.custom is blocked"
if ! grep -q "LD_PRELOAD" "${_ws_env}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.load should not contain LD_PRELOAD" "$(cat "${_ws_env}/env.load" 2> /dev/null)"
fi

# inputs_use_host_env=true should dump environment to env.host
_ws_host="${tmp_dir}/ws_host"
mkdir -p "$_ws_host"
invoke_script --workspace "$_ws_host" inputs_use_host_env="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_host_env=true creates env.host"
if [[ -f "${_ws_host}/env.host" ]]; then
	_pass
else _fail "env.host was not created" "$(last_output)"; fi

# env.host from workspace should be ignored if inputs_use_host_env=false
_ws_host_ignore="${tmp_dir}/ws_host_ignore"
mkdir -p "$_ws_host_ignore"
printf 'EVIL_VAR=bad\n' > "${_ws_host_ignore}/env.host"
invoke_script --workspace "$_ws_host_ignore" inputs_use_host_env="false"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "env.host ignored when inputs_use_host_env=false"
if ! grep -q "EVIL_VAR" "${_ws_host_ignore}/env.load" 2> /dev/null; then
	_pass
else
	_fail "env.host was loaded even though inputs_use_host_env=false" "$(cat "${_ws_host_ignore}/env.load" 2> /dev/null)"
fi

#─────────────────────────────────────────────────────
section "Custom Docker Commands"
#─────────────────────────────────────────────────────

reset_docker_log
invoke_script inputs_custom_docker_commands="--volume /tmp:/tmp"
assert_docker "--volume arg passed to docker run" "/tmp:/tmp"

invoke_script inputs_custom_docker_commands="--env MY_VAR=hello"
assert_docker "--env MY_VAR=value passed to docker run" "MY_VAR=hello"

run_test "unrecognised docker arg exits 1" 1 \
	inputs_custom_docker_commands="--rm"

assert_output "invalid docker arg produces security message" "Security" \
	inputs_custom_docker_commands="--rm"

# Command substitution in a value must be blocked
run_test "command substitution in docker command value exits 1" 1 \
	inputs_custom_docker_commands="--env FOO=\$(cat /etc/passwd)"

# $wd variable is expanded to /home/gh in a volume value.
# Single quotes are intentional: $wd must reach the script unexpanded.
reset_docker_log
# shellcheck disable=SC2016
invoke_script inputs_custom_docker_commands='--volume $wd:/host'
# shellcheck disable=SC2016
assert_docker '$wd expanded to /home/gh in volume arg' "/home/gh:/host"

#─────────────────────────────────────────────────────
section "Security Hardening (docker run flags)"
#─────────────────────────────────────────────────────

# Explicit inputs_platform overrides RUNNER_ARCH
reset_docker_log
invoke_script RUNNER_ARCH="X64" inputs_platform="linux/arm64"
assert_docker "explicit inputs_platform overrides RUNNER_ARCH" "linux/arm64"

# --platform must appear exactly once in the docker run call (no duplicate)
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "--platform not duplicated in docker run"
invoke_script
run_line=$(grep "^run " "${tmp_dir}/docker_calls.log" 2> /dev/null | head -1)
count=$(printf '%s' "$run_line" | grep -o -- "--platform" | wc -l)
if [[ $count -eq 1 ]]; then
	_pass
else _fail "--platform appeared $count times in: $run_line" ""; fi

# --cap-drop ALL present in standard docker run
reset_docker_log
invoke_script
assert_docker "standard docker run has --cap-drop ALL" "--cap-drop ALL"

# -u present when inputs_use_root=false
reset_docker_log
invoke_script inputs_use_root="false"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_root=false -> -u 1001:1001 in docker run"
if grep -qF -- "-u 1001:1001" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
	_pass
else _fail "-u 1001:1001 not found in docker run" "$(docker_log)"; fi

# No -u when inputs_use_root=true
reset_docker_log
invoke_script inputs_use_root="true"
printf '[%d] %s\n' "$((pass_count + fail_count + 1))" "inputs_use_root=true -> no -u flag in docker run"
if ! grep -qF -- "-u 1001" "${tmp_dir}/docker_calls.log" 2> /dev/null; then
	_pass
else _fail "-u 1001 should not appear in docker run" "$(docker_log)"; fi

# Workspace volume mount present
reset_docker_log
invoke_script
assert_docker "workspace volume mounted into container" ":/home/gh"

#─────────────────────────────────────────────────────
section "Source Guard"
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
