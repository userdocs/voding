#!/bin/bash
#
# Offline unit test suite for docker/docker_here.sh.
# External commands (docker, uname, id) are mocked with PATH shims in isolated
# temp directories so nothing touches real containers or the host environment.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker_here_script="${script_dir}/docker_here.sh"
bash_bin="$(command -v bash)"

tmp_root="$(mktemp -d)"
trap 'chmod -R u+w "$tmp_root" 2> /dev/null; rm -rf "$tmp_root"' EXIT

total_tests=0
passed_tests=0
failed_tests=0
failed_names=()

sb=""
rc=0
out=""
err=""

#=============================================================================
# TEST HARNESS & MOCKING
#=============================================================================

section() {
	printf '\n\033[1m── %s ──\033[0m\n' "$1"
}

new_sandbox() {
	sb="$(mktemp -d "${tmp_root}/sb.XXXXXX")"
	mkdir -p "${sb}/bin" "${sb}/work/my_project" "${sb}/home" "${sb}/state"
	: > "${sb}/docker_calls.log"

	# Mock docker CLI supporting stateful ps, start, stop, rm, rmi, run, and exec behaviors
	cat > "${sb}/bin/docker" << 'EOF'
#!/bin/bash
printf 'docker' >> "$MOCK_DOCKER_LOG"
for arg in "$@"; do
	# Collapse newlines to spaces so single-line grep assertions can inspect setup scripts
	flat_arg="${arg//$'\n'/ }"
	printf ' %s' "$flat_arg" >> "$MOCK_DOCKER_LOG"
done
printf '\n' >> "$MOCK_DOCKER_LOG"

subcmd="$1"
shift || true

case "$subcmd" in
	ps)
		all_flag=false
		filter_name=""
		for a in "$@"; do
			[[ $a == "-a" ]] && all_flag=true
			if [[ $a == name=\^/*\$ ]]; then
				filter_name="${a#name=^/}"
				filter_name="${filter_name%\$}"
			fi
		done
		if [[ -f "${MOCK_STATE_DIR}/existing_name" ]]; then
			cname="$(cat "${MOCK_STATE_DIR}/existing_name")"
			if [[ -z $filter_name || $cname == "$filter_name" ]]; then
				if [[ $all_flag == true || -f "${MOCK_STATE_DIR}/is_running" ]]; then
					printf '%s\n' "$cname"
				fi
			fi
		fi
		exit 0
		;;
	start)
		[[ -f "${MOCK_STATE_DIR}/fail_start" ]] && exit 1
		: > "${MOCK_STATE_DIR}/is_running"
		exit 0
		;;
	stop)
		[[ -f "${MOCK_STATE_DIR}/fail_stop" ]] && exit 1
		rm -f "${MOCK_STATE_DIR}/is_running"
		exit 0
		;;
	rm)
		[[ -f "${MOCK_STATE_DIR}/fail_rm" ]] && exit 1
		rm -f "${MOCK_STATE_DIR}/existing_name" "${MOCK_STATE_DIR}/is_running"
		exit 0
		;;
	rmi)
		exit 0
		;;
	run)
		[[ -f "${MOCK_STATE_DIR}/fail_run" ]] && exit 125
		if [[ -f "${MOCK_STATE_DIR}/run_exit_code" ]]; then
			exit "$(cat "${MOCK_STATE_DIR}/run_exit_code")"
		fi
		exit 0
		;;
	exec)
		# Strip flags (-i, -it, -u USER, -w DIR) to inspect target container and command
		while [[ $# -gt 0 ]]; do
			case "$1" in
				-i | -t | -it)
					shift
					;;
				-u | -w)
					shift 2
					;;
				*)
					break
					;;
			esac
		done
		shift || true # container_name

		if [[ $1 == "sh" && $2 == "-c" && $3 == *"command -v bash"* ]]; then
			[[ -f "${MOCK_STATE_DIR}/no_bash" ]] && exit 1
			exit 0
		fi
		if [[ $1 == "test" && $2 == "-d" ]]; then
			[[ -f "${MOCK_STATE_DIR}/no_workdir" ]] && exit 1
			exit 0
		fi
		if [[ $1 == "id" ]]; then
			[[ -f "${MOCK_STATE_DIR}/user_exists" ]] && exit 0
			exit 1
		fi
		if [[ $1 == "sh" && $2 == "-c" ]]; then
			[[ -f "${MOCK_STATE_DIR}/fail_setup" ]] && exit 1
			exit 0
		fi
		if [[ -f "${MOCK_STATE_DIR}/exec_exit_code" ]]; then
			exit "$(cat "${MOCK_STATE_DIR}/exec_exit_code")"
		fi
		exit 0
		;;
esac
exit 0
EOF

	cat > "${sb}/bin/uname" << 'EOF'
#!/bin/bash
if [[ $1 == "-m" ]]; then
	printf '%s\n' "${MOCK_ARCH:-x86_64}"
	exit 0
fi
exec /usr/bin/uname "$@"
EOF

	cat > "${sb}/bin/id" << 'EOF'
#!/bin/bash
if [[ $1 == "-u" ]]; then
	[[ -f "${MOCK_STATE_DIR}/fail_id_u" ]] && exit 1
	printf '%s\n' "${MOCK_UID:-1000}"
	exit 0
fi
if [[ $1 == "-g" ]]; then
	[[ -f "${MOCK_STATE_DIR}/fail_id_g" ]] && exit 1
	printf '%s\n' "${MOCK_GID:-1000}"
	exit 0
fi
if [[ $1 == "-un" ]]; then
	printf '%s\n' "${MOCK_UNAME:-tester}"
	exit 0
fi
exec /usr/bin/id "$@"
EOF

	chmod +x "${sb}/bin/docker" "${sb}/bin/uname" "${sb}/bin/id"
}

docker_log() {
	cat "${sb}/docker_calls.log" 2> /dev/null
}

# Run docker_here.sh as an isolated CLI subprocess in $sb/work/my_project (or custom dir)
invoke_cli() {
	local work_dir="${sb}/work/my_project"
	local -a env_vars=()

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--cwd)
				work_dir="$2"
				shift 2
				;;
			--env)
				env_vars+=("$2")
				shift 2
				;;
			--)
				shift
				break
				;;
			*)
				break
				;;
		esac
	done

	rc=0
	(
		cd "$work_dir" || exit 99
		env -i \
			HOME="${sb}/home" \
			PATH="${sb}/bin:/usr/bin:/bin" \
			MOCK_DOCKER_LOG="${sb}/docker_calls.log" \
			MOCK_STATE_DIR="${sb}/state" \
			NO_COLOR="1" \
			"${env_vars[@]}" \
			"$bash_bin" "$docker_here_script" "$@"
	) > "${sb}/stdout" 2> "${sb}/stderr" || rc=$?

	out="$(cat "${sb}/stdout")"
	err="$(cat "${sb}/stderr")"
}

begin_test() {
	total_tests=$((total_tests + 1))
	new_sandbox
	printf '[%02d] %s ... ' "$total_tests" "$1"
}

pass_test() {
	passed_tests=$((passed_tests + 1))
	printf '\033[32m✓ PASS\033[0m\n'
}

fail_test() {
	local name="$1"
	local reason="$2"
	failed_tests=$((failed_tests + 1))
	failed_names+=("$name")
	printf '\033[31m✗ FAIL\033[0m\n'
	printf '     Reason: %s\n' "$reason"
	if [[ -n $out ]]; then
		printf '     Stdout: %s\n' "${out//$'\n'/ | }"
	fi
	if [[ -n $err ]]; then
		printf '     Stderr: %s\n' "${err//$'\n'/ | }"
	fi
	if [[ -s "${sb}/docker_calls.log" ]]; then
		printf '     Docker: %s\n' "$(tr '\n' '|' < "${sb}/docker_calls.log")"
	fi
}

#=============================================================================
# 1. SYNTAX & SOURCING HYGIENE
#=============================================================================

section "Syntax & Interactive Sourcing Hygiene"

t="Valid bash syntax (bash -n)"
begin_test "$t"
if "$bash_bin" -n "$docker_here_script" 2> "${sb}/stderr"; then
	pass_test
else
	err="$(cat "${sb}/stderr")"
	fail_test "$t" "bash -n failed"
fi

t="Sourcing _dh does not set errexit/pipefail or clobber caller EXIT trap"
begin_test "$t"
rc=0
# shellcheck disable=SC2016
probe_out="$(
	env -i HOME="${sb}/home" PATH="${sb}/bin:/usr/bin:/bin" MOCK_DOCKER_LOG="${sb}/docker_calls.log" MOCK_STATE_DIR="${sb}/state" \
		"$bash_bin" -c '
			trap "printf CALLER_TRAP_OK" EXIT
			set +e +o pipefail
			# shellcheck source=/dev/null
			source "$1"
			_dh -h > /dev/null 2>&1
			_dh -Z > /dev/null 2>&1 || true
			[[ $- != *e* ]] || { printf "ERREXIT_LEAKED"; exit 1; }
			shopt -qo pipefail && { printf "PIPEFAIL_LEAKED"; exit 1; }
			# Verify failing command after _dh does not abort interactive shell
			false || true
			printf "SHELL_ALIVE:"
		' _ "$docker_here_script"
)" || rc=$?
if [[ $rc -eq 0 && $probe_out == "SHELL_ALIVE:CALLER_TRAP_OK" ]]; then
	pass_test
else
	fail_test "$t" "got rc=$rc output='$probe_out'"
fi

t="Sourcing _dh does not leak internal variables into global scope"
begin_test "$t"
rc=0
# shellcheck disable=SC2016
leak_out="$(
	cd "${sb}/work/my_project" && env -i HOME="${sb}/home" PATH="${sb}/bin:/usr/bin:/bin" MOCK_DOCKER_LOG="${sb}/docker_calls.log" MOCK_STATE_DIR="${sb}/state" \
		"$bash_bin" -c '
			# shellcheck source=/dev/null
			source "$1"
			_dh -q -s -P "curl git" > /dev/null 2>&1
			for v in pkg_array pkg setup_script container_name target_user enable_color OPTIND_Check; do
				if [[ -v $v ]]; then
					printf "LEAK:%s" "$v"
					exit 1
				fi
			done
			# Consecutive call in same shell must still parse options cleanly (OPTIND reset)
			_dh -q -u -r > /dev/null 2>&1
			printf "CLEAN"
		' _ "$docker_here_script"
)" || rc=$?
if [[ $rc -eq 0 && $leak_out == "CLEAN" ]] && grep -q "ubuntu:latest" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "got rc=$rc output='$leak_out'"
fi

#=============================================================================
# 2. OPTION PARSING, HELP & OUTPUT MODES
#=============================================================================

section "Option Parsing, Help & Output Modes"

t="Help (-h) succeeds without docker installed in PATH"
begin_test "$t"
rm -f "${sb}/bin/docker"
invoke_cli -h
if [[ $rc -eq 0 && $out == *"Usage: _dh [OPTIONS]"* && -z $err ]]; then
	pass_test
else
	fail_test "$t" "expected exit 0 with Usage on stdout and empty stderr, got rc=$rc"
fi

t="Missing docker binary returns exit code 127"
begin_test "$t"
rm -f "${sb}/bin/docker"
invoke_cli --env PATH="${sb}/bin" -- -q
if [[ $rc -eq 127 && $err == *"Docker is not installed"* ]]; then
	pass_test
else
	fail_test "$t" "expected exit 127, got rc=$rc"
fi

t="Invalid option (-Z) reports specific flag and exits 1"
begin_test "$t"
invoke_cli -Z
if [[ $rc -eq 1 && $err == *"Invalid option -Z"* ]]; then
	pass_test
else
	fail_test "$t" "expected Invalid option -Z error, got rc=$rc"
fi

for flag in p U P i v; do
	t="Missing argument for -${flag} triggers ':' handler and exits 1"
	begin_test "$t"
	invoke_cli "-${flag}"
	if [[ $rc -eq 1 && $err == *"Option -${flag} requires an argument"* ]]; then
		pass_test
	else
		fail_test "$t" "expected missing argument message for -${flag}, got rc=$rc"
	fi
done

t="Empty argument to -v (-v '') exits 1"
begin_test "$t"
invoke_cli -v ""
if [[ $rc -eq 1 && $err == *"-v requires a directory path"* ]]; then
	pass_test
else
	fail_test "$t" "expected -v empty path rejection, got rc=$rc"
fi

t="Unexpected trailing positional argument is rejected"
begin_test "$t"
invoke_cli -q ubuntu
if [[ $rc -eq 1 && $err == *"Unexpected argument: 'ubuntu'"* ]]; then
	pass_test
else
	fail_test "$t" "expected unexpected argument rejection, got rc=$rc"
fi

t="Quiet mode (-q) suppresses DEBUG output even when passed last (-u -s -q)"
begin_test "$t"
invoke_cli -u -s -q
if [[ $rc -eq 0 && $err != *"DEBUG:"* ]]; then
	pass_test
else
	fail_test "$t" "expected no DEBUG output when -q is last, got rc=$rc"
fi

t="Non-quiet mode emits DEBUG trace to stderr"
begin_test "$t"
invoke_cli -u
if [[ $rc -eq 0 && $err == *"DEBUG: Processing option: u"* && $err == *"DEBUG: Final values"* ]]; then
	pass_test
else
	fail_test "$t" "expected DEBUG output on stderr, got rc=$rc"
fi

#=============================================================================
# 3. DISTROS, IMAGES & PLATFORMS
#=============================================================================

section "Distros, Images & Platforms"

t="Default behavior uses alpine:edge in persistent mode"
begin_test "$t"
invoke_cli -q
if [[ $rc -eq 0 ]] && grep -qE "^docker run -d --init --platform linux/amd64 --name alpine_my_project .* alpine:edge tail -f /dev/null$" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "unexpected docker run command"
fi

t="Ubuntu (-u) sets ubuntu:latest and noninteractive locale env vars"
begin_test "$t"
invoke_cli -q -u
if [[ $rc -eq 0 ]] \
	&& grep -q "DEBIAN_FRONTEND=noninteractive" "${sb}/docker_calls.log" \
	&& grep -q "ubuntu:latest" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "ubuntu flags/env missing"
fi

t="Debian (-d) sets debian:latest and noninteractive locale env vars"
begin_test "$t"
invoke_cli -q -d
if [[ $rc -eq 0 ]] \
	&& grep -q "DEBIAN_FRONTEND=noninteractive" "${sb}/docker_calls.log" \
	&& grep -q "debian:latest" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "debian flags/env missing"
fi

t="Alpine flag (-a) after -u resets image to alpine:edge without Debian env vars"
begin_test "$t"
invoke_cli -q -u -a
if [[ $rc -eq 0 ]] \
	&& grep -q "alpine:edge" "${sb}/docker_calls.log" \
	&& ! grep -q "DEBIAN_FRONTEND" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected alpine:edge without DEBIAN_FRONTEND"
fi

t="Custom image (-i debian:bookworm-slim) parses distro and tag"
begin_test "$t"
invoke_cli -q -i debian:bookworm-slim
if [[ $rc -eq 0 ]] && grep -q "debian:bookworm-slim" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected debian:bookworm-slim"
fi

for bad_img in "fedora:latest" "alpine" "alpine:" "alpine:edge;id" "ubuntu:22.04 --privileged" "debian:-badtag"; do
	t="Invalid image spec rejected: '${bad_img}'"
	begin_test "$t"
	invoke_cli -q -i "$bad_img"
	if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
		pass_test
	else
		fail_test "$t" "expected exit 1 with zero docker calls, got rc=$rc"
	fi
done

for pair in "aarch64:linux/arm64" "armv7l:linux/arm/v7" "armv6l:linux/arm/v6" "i686:linux/386" "ppc64le:linux/ppc64le" "riscv64:linux/riscv64" "s390x:linux/s390x" "mips64:linux/amd64"; do
	arch="${pair%%:*}"
	plat="${pair#*:}"
	t="Auto-detects platform ${plat} from uname -m=${arch}"
	begin_test "$t"
	invoke_cli --env "MOCK_ARCH=${arch}" -- -q
	if [[ $rc -eq 0 ]] && grep -q -- "--platform ${plat}" "${sb}/docker_calls.log"; then
		pass_test
	else
		fail_test "$t" "expected --platform ${plat}"
	fi
done

t="Custom platform (-p linux/arm64/v8) is honored"
begin_test "$t"
invoke_cli -q -p "linux/arm64/v8"
if [[ $rc -eq 0 ]] && grep -q -- "--platform linux/arm64/v8" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected --platform linux/arm64/v8"
fi

for bad_plat in "linux" "linux/amd64;id" "--privileged" "linux/arm/v7/extra"; do
	t="Invalid platform rejected: '${bad_plat}'"
	begin_test "$t"
	invoke_cli -q -p "$bad_plat"
	if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
		pass_test
	else
		fail_test "$t" "expected exit 1 for bad platform '${bad_plat}', got rc=$rc"
	fi
done

#=============================================================================
# 4. USER MODES, UID/GID & SECURITY VALIDATION
#=============================================================================

section "User Modes, UID/GID & Security Validation"

t="Root mode defaults to 'gh' without false warning even when host USER=ubuntu"
begin_test "$t"
invoke_cli --env "USER=ubuntu" -- -q
if [[ $rc -eq 0 && $err != *"WARNING: Custom user"* ]] \
	&& grep -q -- "--security-opt no-new-privileges" "${sb}/docker_calls.log" \
	&& grep -q -- "-v ${sb}/work/my_project:/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "unexpected warning or flags in root mode"
fi

t="Sudo mode (-s) configures sudoers, omits no-new-privileges, and avoids chown -R / host dotfile pollution"
begin_test "$t"
invoke_cli -q -s
log_content="$(docker_log)"
if [[ $rc -eq 0 ]] \
	&& [[ $log_content != *"no-new-privileges"* ]] \
	&& [[ $log_content == *"-v ${sb}/work/my_project:/home/gh"* ]] \
	&& [[ $log_content == *"/etc/sudoers.d/gh"* ]] \
	&& [[ $log_content != *"chown -R"* ]] \
	&& [[ $log_content != *"touch \"/home/"* ]]; then
	pass_test
else
	fail_test "$t" "sudo mode setup did not match security expectations"
fi

t="Limited mode (-l) creates non-root user with no-new-privileges and without sudo"
begin_test "$t"
invoke_cli -q -l
log_content="$(docker_log)"
if [[ $rc -eq 0 ]] \
	&& [[ $log_content == *"--security-opt no-new-privileges"* ]] \
	&& [[ $log_content == *"useradd"* ]] \
	&& [[ $log_content != *"/etc/sudoers.d/gh"* ]]; then
	pass_test
else
	fail_test "$t" "limited mode setup mismatch"
fi

t="Conflicting -s and -l flags fail with exit 1"
begin_test "$t"
invoke_cli -q -s -l
if [[ $rc -eq 1 && $err == *"cannot be used together"* && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "expected conflict error"
fi

t="Custom user (-U dev_user -s) mounts /home/dev_user and attaches as dev_user"
begin_test "$t"
invoke_cli -q -s -U dev_user
log_content="$(docker_log)"
if [[ $rc -eq 0 && $log_content == *":/home/dev_user"* && $log_content == *"-u dev_user"* ]]; then
	pass_test
else
	fail_test "$t" "custom user not applied"
fi

t="Custom user (-U customuser) without -s or -l warns on stderr and runs as root"
begin_test "$t"
invoke_cli -q -U customuser
if [[ $rc -eq 0 && $err == *"WARNING: Custom user (-U customuser)"* ]] \
	&& grep -q -- ":/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected custom user warning in root mode"
fi

t="Username 'root' (-U root) is rejected to prevent overwriting container UID 0"
begin_test "$t"
invoke_cli -q -s -U root
if [[ $rc -eq 1 && $err == *"Username 'root' cannot be specified"* ]]; then
	pass_test
else
	fail_test "$t" "expected -U root rejection"
fi

for bad_user in "invalid;user" "9bad" "Upper" "-dash" "a_very_long_username_exceeding_32_characters"; do
	t="Invalid username rejected: '${bad_user}'"
	begin_test "$t"
	invoke_cli -q -s -U "$bad_user"
	if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
		pass_test
	else
		fail_test "$t" "expected exit 1 for username '${bad_user}'"
	fi
done

t="Host UID/GID 0 maps to 1000:1000 inside user-mode container"
begin_test "$t"
invoke_cli --env "MOCK_UID=0" --env "MOCK_GID=0" -- -q -l
if [[ $rc -eq 0 ]] && grep -q -- '-u "1000" -g "1000"' "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected UID/GID 0 to map to 1000:1000"
fi

t="Numeric SUDO_UID and SUDO_GID override host UID/GID"
begin_test "$t"
invoke_cli --env "SUDO_UID=1042" --env "SUDO_GID=1043" -- -q -l
if [[ $rc -eq 0 ]] && grep -q -- '-u "1042" -g "1043"' "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected SUDO_UID=1042 SUDO_GID=1043"
fi

t="Security: Malicious SUDO_UID arithmetic/command injection payload is blocked"
begin_test "$t"
pwn_file="${sb}/pwned"
invoke_cli --env "SUDO_UID=a[\$(touch ${pwn_file})]" -- -q -l
if [[ $rc -eq 1 && ! -e $pwn_file && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "SUDO_UID injection was not blocked cleanly (rc=$rc)"
fi

t="Security: Malicious SUDO_GID payload is blocked"
begin_test "$t"
invoke_cli --env "SUDO_GID=1000;id" -- -q -l
if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "SUDO_GID injection was not blocked cleanly"
fi

#=============================================================================
# 5. PACKAGE VALIDATION & INJECTION HARDENING
#=============================================================================

section "Package Validation & Injection Hardening"

t="Valid packages (-P 'curl wget g++ python3.11') are passed to package manager"
begin_test "$t"
invoke_cli -q -s -P "curl wget g++ python3.11"
if [[ $rc -eq 0 ]] && grep -q "sudo curl wget g++ python3.11" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected validated package list in setup script"
fi

t="Security: Shell metacharacters in -P are blocked"
begin_test "$t"
invoke_cli -q -P "bad-pkg; rm -rf /"
if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "expected command injection payload in -P to fail"
fi

t="Security: Multiline package injection (-P $'curl\\nid') is blocked"
begin_test "$t"
invoke_cli -q -P $'curl\nid'
if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "multiline -P bypass was not blocked"
fi

t="Security: Leading hyphen option injection in -P is blocked"
begin_test "$t"
invoke_cli -q -P "-o APT::Update::Pre-Invoke=id"
if [[ $rc -eq 1 && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "leading hyphen option in -P was not blocked"
fi

#=============================================================================
# 6. VOLUME PATH RESOLUTION & SIDE-EFFECT SAFETY
#=============================================================================

section "Volume Path Resolution & Side-Effect Safety"

t="Absolute volume path (-v) creates directory and mounts it"
begin_test "$t"
vol_dir="${sb}/custom_vol"
invoke_cli -q -v "$vol_dir"
if [[ $rc -eq 0 && -d $vol_dir ]] && grep -q -- "-v ${vol_dir}:/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "custom absolute volume failed"
fi

t="Relative volume path (-v sub/vol) resolves relative to PWD"
begin_test "$t"
invoke_cli -q -v "sub/vol"
expected_vol="${sb}/work/my_project/sub/vol"
if [[ $rc -eq 0 && -d $expected_vol ]] && grep -q -- "-v ${expected_vol}:/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "relative volume path failed"
fi

t="Tilde volume path (-v ~/proj_vol) expands HOME safely"
begin_test "$t"
# shellcheck disable=SC2088
invoke_cli -q -v "~/proj_vol"
expected_vol="${sb}/home/proj_vol"
if [[ $rc -eq 0 && -d $expected_vol ]] && grep -q -- "-v ${expected_vol}:/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "tilde volume expansion failed"
fi

t="Bare tilde volume path (-v ~) expands directly to HOME"
begin_test "$t"
invoke_cli -q -v "~"
if [[ $rc -eq 0 ]] && grep -q -- "-v ${sb}/home:/root" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "bare tilde volume expansion failed"
fi

t="Unsupported ~otheruser tilde expansion is rejected instead of corrupting path"
begin_test "$t"
invoke_cli -q -v "~otheruser/vol"
if [[ $rc -eq 1 && $err == *"Unsupported tilde path"* ]]; then
	pass_test
else
	fail_test "$t" "expected ~otheruser rejection"
fi

t="Tilde path with empty HOME fails safely without writing to /"
begin_test "$t"
# shellcheck disable=SC2088
invoke_cli --env "HOME=" -- -q -v "~/vol"
if [[ $rc -eq 1 && $err == *"HOME is not set"* ]]; then
	pass_test
else
	fail_test "$t" "expected empty HOME error"
fi

t="Security: Colon in volume path (-v /path:evil) is rejected to prevent mount hijacking"
begin_test "$t"
invoke_cli -q -v "${sb}/bad:mount:/etc"
if [[ $rc -eq 1 && $err == *"cannot contain colons"* && ! -s "${sb}/docker_calls.log" ]]; then
	pass_test
else
	fail_test "$t" "expected colon in volume path to be rejected"
fi

t="No mkdir side effect when -v is combined with -h or invalid flags"
begin_test "$t"
no_dir_h="${sb}/should_not_exist_h"
no_dir_err="${sb}/should_not_exist_err"
invoke_cli -v "$no_dir_h" -h
rc_h=$rc
invoke_cli -v "$no_dir_err" -s -l
rc_err=$rc
if [[ $rc_h -eq 0 && $rc_err -eq 1 && ! -e $no_dir_h && ! -e $no_dir_err ]]; then
	pass_test
else
	fail_test "$t" "directory was created prematurely before validation/help"
fi

t="Non-writable volume directory emits WARNING to stderr"
begin_test "$t"
ro_dir="${sb}/ro_vol"
mkdir -p "$ro_dir"
chmod 0555 "$ro_dir"
# Only non-root host users observe ! -w on 0555 directories
if [[ ! -w $ro_dir ]]; then
	invoke_cli -q -v "$ro_dir"
	chmod 0755 "$ro_dir"
	if [[ $rc -eq 0 && $err == *"WARNING: Volume path"* && $out != *"WARNING: Volume path"* ]]; then
		pass_test
	else
		fail_test "$t" "expected non-writable warning on stderr"
	fi
else
	chmod 0755 "$ro_dir"
	pass_test
fi

#=============================================================================
# 7. CONTAINER LIFECYCLE, REUSE, EPHEMERAL & SHELL ATTACHMENT
#=============================================================================

section "Container Lifecycle, Reuse, Ephemeral & Shell Attachment"

t="Ephemeral mode (-r) uses --init --rm, avoids 'su -p', and propagates container exit code"
begin_test "$t"
printf '42\n' > "${sb}/state/run_exit_code"
invoke_cli -q -r -s
log_content="$(docker_log)"
if [[ $rc -eq 42 ]] \
	&& [[ $log_content == *"docker run -i --init --rm"* ]] \
	&& [[ $log_content == *"exec su -s /bin/bash \"gh\""* ]] \
	&& [[ $log_content != *"su -p"* ]]; then
	pass_test
else
	fail_test "$t" "ephemeral mode behavior/exit code mismatch (rc=$rc)"
fi

t="Ephemeral mode (-r) does not hijack existing persistent container and avoids name collision"
begin_test "$t"
printf 'alpine_my_project\n' > "${sb}/state/existing_name"
: > "${sb}/state/is_running"
invoke_cli -q -r
log_content="$(docker_log)"
if [[ $rc -eq 0 && $err != *"Reusing existing container"* ]] \
	&& grep -qE "^docker run -i --init --rm --platform linux/amd64 --name alpine_my_project_ephemeral_[0-9]+" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "ephemeral mode collided with or hijacked persistent container"
fi

t="Container reuse starts stopped container and attaches as target_user when present"
begin_test "$t"
printf 'alpine_my_project\n' > "${sb}/state/existing_name"
: > "${sb}/state/user_exists"
invoke_cli -q
log_content="$(docker_log)"
if [[ $rc -eq 0 && $err == *"Reusing existing container: alpine_my_project"* ]] \
	&& grep -q "^docker start alpine_my_project$" "${sb}/docker_calls.log" \
	&& grep -q "^docker exec -i -u gh -w /home/gh alpine_my_project bash$" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "container reuse failed to start and attach as gh"
fi

t="Container reuse fails cleanly if docker start fails instead of exec-ing into stopped container"
begin_test "$t"
printf 'alpine_my_project\n' > "${sb}/state/existing_name"
: > "${sb}/state/fail_start"
invoke_cli -q
if [[ $rc -eq 1 && $err == *"Failed to start existing container"* ]] \
	&& ! grep -q "^docker exec" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected failure when docker start fails"
fi

t="Force new (-n) stops and removes existing running container before creating new one"
begin_test "$t"
printf 'alpine_my_project\n' > "${sb}/state/existing_name"
: > "${sb}/state/is_running"
invoke_cli -q -n
if [[ $rc -eq 0 ]] \
	&& grep -q "^docker stop alpine_my_project$" "${sb}/docker_calls.log" \
	&& grep -q "^docker rm -f alpine_my_project$" "${sb}/docker_calls.log" \
	&& grep -q "^docker run -d --init" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected stop + rm -f + run on -n"
fi

t="Delete all (-D) removes existing container and image before creating fresh container"
begin_test "$t"
printf 'alpine_my_project\n' > "${sb}/state/existing_name"
: > "${sb}/state/is_running"
invoke_cli -q -D
if [[ $rc -eq 0 ]] \
	&& grep -q "^docker rm -f alpine_my_project$" "${sb}/docker_calls.log" \
	&& grep -q "^docker rmi -f alpine:edge$" "${sb}/docker_calls.log" \
	&& grep -q "^docker run -d --init" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected rm -f + rmi -f + run on -D"
fi

t="Persistent setup failure returns exit 1 with error message"
begin_test "$t"
: > "${sb}/state/fail_setup"
invoke_cli -q
if [[ $rc -eq 1 && $err == *"Failed to setup persistent container"* ]]; then
	pass_test
else
	fail_test "$t" "expected setup failure to return 1"
fi

t="Shell attachment falls back to sh when bash is absent and omits -w when workdir is missing"
begin_test "$t"
: > "${sb}/state/no_bash"
: > "${sb}/state/no_workdir"
invoke_cli -q
if [[ $rc -eq 0 ]] && grep -q "^docker exec -i alpine_my_project sh$" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected fallback to sh without -w"
fi

t="_dh_attach_shell honors prefer_bash=false even when bash is available"
begin_test "$t"
rc=0
# shellcheck disable=SC2016
(
	env -i HOME="${sb}/home" PATH="${sb}/bin:/usr/bin:/bin" MOCK_DOCKER_LOG="${sb}/docker_calls.log" MOCK_STATE_DIR="${sb}/state" \
		"$bash_bin" -c '
			# shellcheck source=/dev/null
			source "$1"
			_dh_attach_shell "test_ctr" "gh" "/home/gh" false
		' _ "$docker_here_script"
) > "${sb}/stdout" 2> "${sb}/stderr" || rc=$?
if [[ $rc -eq 0 ]] && grep -q "^docker exec -i -u gh -w /home/gh test_ctr sh$" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected prefer_bash=false to select sh"
fi

t="Directory slug sanitization handles special/dot-only names safely"
begin_test "$t"
weird_dir="${sb}/work/..."
mkdir -p "$weird_dir"
invoke_cli --cwd "$weird_dir" -- -q
if [[ $rc -eq 0 ]] && grep -q -- "--name alpine_workspace" "${sb}/docker_calls.log"; then
	pass_test
else
	fail_test "$t" "expected fallback container name alpine_workspace"
fi

#=============================================================================
# SUMMARY
#=============================================================================

printf '\n=== SUMMARY ===\n'
printf 'Total tests: %d\n' "$total_tests"
printf 'Passed:      %d\n' "$passed_tests"
printf 'Failed:      %d\n' "$failed_tests"

if [[ $failed_tests -eq 0 ]]; then
	printf '\nALL TESTS PASSED!\n'
	exit 0
else
	printf '\nFailed tests:\n'
	for name in "${failed_names[@]}"; do
		printf '  - %s\n' "$name"
	done
	exit 1
fi
