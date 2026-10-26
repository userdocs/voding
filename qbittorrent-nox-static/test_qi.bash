#!/bin/bash
# Offline test suite for qi.bash. Every external command (curl, wget, apk, dpkg, gh, ...) is
# mocked with PATH shims and /etc/os-release is redirected, so nothing touches the network or host.
# Usage: ./test_qi.bash [name-filter]

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qi_src="$script_dir/qi.bash"
bash_bin="$(command -v bash)"

tmp_root="$(mktemp -d)"
trap 'chmod -R u+w "$tmp_root" 2> /dev/null; rm -rf "$tmp_root"' EXIT

# Fixture constants (match the mock release JSON written by write_release_json)
tag_12="release-5.3.0_v1.2.20"
tag_20="release-5.3.0_v2.0.15"
tag_21="release-5.3.0_v2.1.2"
release_base="https://github.com/userdocs/qbittorrent-nox-static/releases/download"
fake_sha="$(printf '0%.0s' {1..64})"
abc_sha="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

sandbox_count=0
assertions=0
failures=()
skip_reason=""
total_tests=0
passed_tests=0
failed_tests=0
skipped_tests=0
failed_names=()

# Per-sandbox state, reset by new_sandbox
sb=""
qi_env=()
qi_path=""
rc=0
out=""
err=""

# ── Assertions ────────────────────────────────────────────────────────────────

# record_failure <name> [detail...]
record_failure() {
	local name="$1" detail msg
	shift
	printf -v msg '    - %s' "$name"
	for detail in "$@"; do
		msg+=$'\n'"        $detail"
	done
	failures+=("$msg")
}

assert_eq() {
	((assertions++))
	[[ $2 == "$3" ]] || record_failure "$1" "expected: [$2]" "actual:   [$3]"
}

assert_contains() {
	((assertions++))
	[[ $2 == *"$3"* ]] || record_failure "$1" "missing: [$3]" "in: [${2:0:400}]"
}

assert_not_contains() {
	((assertions++))
	[[ $2 != *"$3"* ]] || record_failure "$1" "unexpected: [$3]" "in: [${2:0:400}]"
}

# assert_rc <name> <expected> - checks $rc from the last run
assert_rc() {
	((assertions++))
	if [[ $rc -ne $2 ]]; then
		record_failure "$1" "expected exit $2, got $rc" "stderr tail: $(printf '%s' "$err" | tail -n 4 | tr '\n' '|')"
	fi
}

assert_rc_nonzero() {
	((assertions++))
	if [[ $rc -eq 0 ]]; then
		record_failure "$1" "expected non-zero exit, got 0"
	fi
}

assert_file() {
	((assertions++))
	[[ -f $2 ]] || record_failure "$1" "file missing: $2"
}

assert_no_file() {
	((assertions++))
	[[ ! -e $2 ]] || record_failure "$1" "file should not exist: $2"
}

assert_executable() {
	((assertions++))
	[[ -x $2 ]] || record_failure "$1" "not executable: $2"
}

assert_same_file() {
	((assertions++))
	cmp -s "$2" "$3" || record_failure "$1" "files differ: $2 vs $3"
}

# assert_called / assert_not_called check the mock call log (<tool> <url-or-args> per line)
assert_called() {
	((assertions++))
	[[ "$(calls_log)" == *"$2"* ]] || record_failure "$1" "no call matching: [$2]" "calls: $(calls_log | tr '\n' '|')"
}

assert_not_called() {
	((assertions++))
	[[ "$(calls_log)" != *"$2"* ]] || record_failure "$1" "unexpected call matching: [$2]"
}

# ── Sandbox construction ──────────────────────────────────────────────────────

calls_log() {
	cat "$sb/mock/calls.log" 2> /dev/null
}

bin_listing() {
	ls -A "$sb/home/bin" 2> /dev/null
}

# make_shim <name> - body is read from stdin
make_shim() {
	{
		printf '#!%s\n' "$bash_bin"
		cat
	} > "$sb/shim/$1"
	chmod +x "$sb/shim/$1"
}

remove_tool() {
	rm -f "$sb/shim/$1" "$sb/tools/$1"
}

# add_real_tool <name> - expose a host tool inside the sandbox PATH; returns 1 if the host lacks it
add_real_tool() {
	local path
	path="$(command -v "$1")" || return 1
	ln -sf "$path" "$sb/tools/$1"
}

need_tool() {
	if ! command -v "$1" > /dev/null 2>&1; then
		skip_reason="$1 not installed"
		return 1
	fi
}

# Shared fetch logic for the curl and wget shims, driven by flag files in $MOCK_DIR
install_serve() {
	cat > "$sb/mock/serve.bash" << 'EOF'
mock_serve() {
	local tool="$1" url="$2" out="$3" body=""
	printf '%s %s\n' "$tool" "$url" >> "$MOCK_DIR/calls.log"
	case "$url" in
		*/dependency-version.json)
			[[ -e $MOCK_DIR/fail_release ]] && return 22
			body="$MOCK_DIR/release.json"
			;;
		https://api.github.com/*)
			[[ -e $MOCK_DIR/fail_api ]] && return 22
			body="$MOCK_DIR/api.json"
			;;
		*-qbittorrent-nox)
			if [[ -e $MOCK_DIR/fail_download ]]; then
				[[ -n $out ]] && printf 'partial' > "$out"
				return 22
			fi
			body="$MOCK_DIR/binary"
			[[ -e $MOCK_DIR/empty_download ]] && body=/dev/null
			;;
		*) return 22 ;;
	esac
	if [[ -n $out ]]; then
		cat "$body" > "$out"
	else
		cat "$body"
	fi
}
EOF
}

add_curl() {
	make_shim curl << 'EOF'
source "$MOCK_DIR/serve.bash"
out="" url=""
while (($#)); do
	case "$1" in
		-o) out="$2"; shift ;;
		http*) url="$1" ;;
	esac
	shift
done
mock_serve curl "$url" "$out"
EOF
}

add_wget() {
	make_shim wget << 'EOF'
source "$MOCK_DIR/serve.bash"
out="" url=""
while (($#)); do
	case "$1" in
		-qO-) out="" ;;
		-qO) out="$2"; shift ;;
		http*) url="$1" ;;
	esac
	shift
done
mock_serve wget "$url" "$out"
EOF
}

add_gh() {
	make_shim gh << 'EOF'
printf 'gh %s\n' "$*" >> "$MOCK_DIR/calls.log"
[[ -e $MOCK_DIR/gh_fail ]] && exit 1
exit 0
EOF
}

# set_arch <apk|dpkg|arch> <value> - install/refresh an architecture detection shim
set_arch() {
	local tool="$1" value="$2" flag=""
	case "$tool" in
		apk) flag="--print-arch" ;;
		dpkg) flag="--print-architecture" ;;
	esac
	printf '%s\n' "$value" > "$sb/mock/${tool}_out"
	make_shim "$tool" << EOF
[[ -e "\$MOCK_DIR/${tool}_fail" ]] && exit 1
[[ -z "$flag" || \$1 == "$flag" ]] || exit 1
cat "\$MOCK_DIR/${tool}_out"
EOF
}

# write_release_json [omitted-key...] - the revision value comes from $release_revision
write_release_json() {
	local omit=" $* " line key
	{
		printf '{\n'
		for line in "openssl:3.5.4" "boost:1.89.0" "libtorrent_1_2:1.2.20" "libtorrent_2_0:2.0.15" \
			"libtorrent_2_1:2.1.2" "qt6:6.9.3" "qbittorrent:5.3.0"; do
			key="${line%%:*}"
			[[ $omit == *" $key "* ]] || printf '  "%s": "%s",\n' "$key" "${line#*:}"
		done
		[[ $omit == *" revision "* ]] || printf '  "revision": "%s"\n' "${release_revision:-0}"
		printf '}\n'
	} > "$sb/mock/release.json"
}

# write_api_json <sha...> - pretty-printed like the real GitHub API
write_api_json() {
	local digest sep=""
	{
		printf '{\n  "tag_name": "x",\n  "assets": [\n'
		for digest in "$@"; do
			printf '%s    {\n      "name": "asset",\n      "digest": "sha256:%s"\n    }' "$sep" "$digest"
			sep=$',\n'
		done
		printf '\n  ]\n}\n'
	} > "$sb/mock/api.json"
}

# write_api_json_compact <sha...> - single-line JSON
write_api_json_compact() {
	local digest sep="" body=""
	for digest in "$@"; do
		body+="${sep}{\"name\":\"asset\",\"digest\":\"sha256:${digest}\"}"
		sep=","
	done
	printf '{"tag_name":"x","assets":[%s]}\n' "$body" > "$sb/mock/api.json"
}

binary_sha() {
	sha256sum "$sb/mock/binary" | cut -d' ' -f1
}

# set_binary <good|broken|execformat> - the downloadable fixture, api.json is refreshed to match
set_binary() {
	local body
	case "$1" in
		good) body='printf "qBittorrent v9.9.9\n"' ;;
		broken) body='printf "boom\n" >&2; exit 3' ;;
		execformat) body='printf "cannot execute binary file: Exec format error\n" >&2; exit 126' ;;
	esac
	printf '#!%s\n%s\n' "$bash_bin" "$body" > "$sb/mock/binary"
	write_api_json "$(binary_sha)"
}

seed_existing() {
	mkdir -p "$sb/home/bin"
	printf 'old-binary' > "$sb/home/bin/qbittorrent-nox"
	chmod 755 "$sb/home/bin/qbittorrent-nox"
}

set_os_release() {
	printf "$1" > "$sb/os-release"
}

new_sandbox() {
	local tool path
	((sandbox_count++))
	sb="$tmp_root/sb$sandbox_count"
	mkdir -p "$sb/shim" "$sb/tools" "$sb/home" "$sb/mock"

	for tool in sed cut head mkdir chmod mv rm mktemp sha256sum cat cp tr grep; do
		path="$(command -v "$tool")" && ln -s "$path" "$sb/tools/$tool"
	done

	: > "$sb/mock/calls.log"
	install_serve
	add_curl
	set_arch dpkg amd64
	set_os_release 'ID=ubuntu\nID_LIKE=debian\n'
	release_revision=0
	write_release_json
	set_binary good

	# Copies of the script with /etc/os-release redirected; the lib copy has main and the parser removed
	sed "s|/etc/os-release|$sb/os-release|g" "$qi_src" > "$sb/qi.bash"
	sed -e "s|/etc/os-release|$sb/os-release|g" -e '/^# Simple argument parsing/,$d' "$qi_src" > "$sb/qi_lib.bash"

	qi_env=()
	qi_path=""
	skip_reason=""
}

# ── Runners ───────────────────────────────────────────────────────────────────

# _capture <cmd...> - run in a scrubbed environment; sets rc, out (stdout) and err (stderr, ANSI stripped)
_capture() {
	env -i HOME="$sb/home" PATH="${qi_path:-$sb/shim:$sb/tools}" LC_ALL=C.UTF-8 MOCK_DIR="$sb/mock" \
		"${qi_env[@]}" "$@" > "$sb/stdout" 2> "$sb/stderr.raw"
	rc=$?
	out="$(< "$sb/stdout")"
	err="$(sed 's/\x1b\[[0-9;]*m//g' "$sb/stderr.raw")"
}

run_qi() {
	_capture "$bash_bin" "$sb/qi.bash" "$@"
}

# run_lib <function> [args...] - call a function from the sourced (side-effect free) copy
run_lib() {
	_capture "$bash_bin" -c 'source "$1"; shift; "$@"' _ "$sb/qi_lib.bash" "$@"
}

# ══════════════════════════════════════════════════════════════════════════════
# Static checks
# ══════════════════════════════════════════════════════════════════════════════

test_static_syntax() {
	bash -n "$qi_src" 2> "$sb/syntax.err"
	rc=$?
	err="$(< "$sb/syntax.err")"
	assert_rc "qi.bash parses" 0
}

test_static_shellcheck() {
	need_tool shellcheck || return
	local report
	report="$(shellcheck -S warning "$qi_src" 2>&1)"
	assert_eq "qi.bash has no shellcheck warnings" "" "$report"
	report="$(shellcheck -S warning "${BASH_SOURCE[0]}" 2>&1)"
	assert_eq "test_qi.bash has no shellcheck warnings" "" "$report"
}

test_static_shfmt() {
	local shfmt_bin
	shfmt_bin="$(command -v shfmt || true)"
	[[ -z $shfmt_bin && -x $HOME/bin/shfmt ]] && shfmt_bin="$HOME/bin/shfmt"
	if [[ -z $shfmt_bin ]]; then
		skip_reason="shfmt not installed"
		return
	fi
	local diff_out
	diff_out="$("$shfmt_bin" -s -bn -ci -sr -i 0 -d "$qi_src" 2>&1)"
	assert_eq "qi.bash is shfmt formatted" "" "$diff_out"
}

test_static_conventions() {
	assert_eq "shebang is #!/bin/bash" "#!/bin/bash" "$(head -n 1 "$qi_src")"
	assert_not_contains "no echo calls" "$(grep -nE '^[[:space:]]*echo[[:space:]]' "$qi_src")" "echo"
	assert_not_contains "no global set -e/-u/pipefail" "$(grep -nE '^set -' "$qi_src")" "set"
}

# ══════════════════════════════════════════════════════════════════════════════
# Unit tests (functions sourced from the lib copy)
# ══════════════════════════════════════════════════════════════════════════════

test_unit_validate_arch_accepts() {
	local arch
	for arch in x86_64 x86 aarch64 armv7 armhf riscv64; do
		run_lib validate_arch "$arch"
		assert_rc "accepts $arch" 0
	done
}

test_unit_validate_arch_rejects() {
	local arch
	for arch in bogus "" x86-64 X86_64 arm64 amd64 "aarch64 "; do
		run_lib validate_arch "$arch"
		assert_rc "rejects [$arch]" 1
		assert_contains "explains [$arch]" "$err" "Unsupported architecture"
	done
}

test_unit_create_download_url() {
	run_lib create_download_url aarch64 "$tag_21"
	assert_eq "url format" "$release_base/$tag_21/aarch64-qbittorrent-nox" "$out"
}

test_unit_detect_arch_apk() {
	local pair
	remove_tool dpkg
	for pair in x86_64:x86_64 x86:x86 aarch64:aarch64 armv7:armv7 armhf:armhf riscv64:riscv64; do
		set_arch apk "${pair%%:*}"
		run_lib detect_arch
		assert_eq "apk ${pair%%:*}" "${pair#*:}" "$out"
		assert_rc "apk ${pair%%:*} exit" 0
	done
}

test_unit_detect_arch_dpkg() {
	local pair
	for pair in amd64:x86_64 i386:x86 arm64:aarch64 armhf:armv7 armel:armhf riscv64:riscv64; do
		set_arch dpkg "${pair%%:*}"
		run_lib detect_arch
		assert_eq "dpkg ${pair%%:*}" "${pair#*:}" "$out"
		assert_rc "dpkg ${pair%%:*} exit" 0
	done
}

test_unit_detect_arch_arch_fallback() {
	local pair
	remove_tool dpkg
	for pair in x86_64:x86_64 i686:x86 aarch64:aarch64 armv7l:armv7 armv6l:armhf riscv64:riscv64; do
		set_arch arch "${pair%%:*}"
		run_lib detect_arch
		assert_eq "arch ${pair%%:*}" "${pair#*:}" "$out"
	done
}

test_unit_detect_arch_prefers_apk() {
	set_arch apk aarch64
	set_arch dpkg amd64
	run_lib detect_arch
	assert_eq "apk wins over dpkg" "aarch64" "$out"
}

test_unit_detect_arch_unsupported() {
	set_arch dpkg s390x
	run_lib detect_arch
	assert_rc "unsupported dpkg arch exits 1" 1
	assert_contains "names the arch" "$err" "Unsupported architecture: s390x"
	assert_eq "nothing on stdout" "" "$out"

	remove_tool dpkg
	set_arch apk ppc64le
	run_lib detect_arch
	assert_rc "unsupported apk arch exits 1" 1
	assert_contains "names the apk arch" "$err" "Unsupported architecture: ppc64le"
}

test_unit_detect_arch_tool_failure() {
	touch "$sb/mock/dpkg_fail"
	run_lib detect_arch
	assert_rc "dpkg failure exits 1" 1
	assert_contains "dpkg failure message" "$err" "Failed to detect architecture using dpkg"

	remove_tool dpkg
	set_arch apk x86_64
	touch "$sb/mock/apk_fail"
	run_lib detect_arch
	assert_rc "apk failure exits 1" 1
	assert_contains "apk failure message" "$err" "Failed to detect architecture using apk"
}

test_unit_detect_arch_no_tool() {
	remove_tool dpkg
	run_lib detect_arch
	assert_rc "no tool exits 1" 1
	assert_contains "no tool message" "$err" "No architecture detection tool found"
}

test_unit_check_download_tools() {
	add_wget
	run_lib check_download_tools
	assert_eq "curl preferred when both exist" "curl" "$out"

	remove_tool curl
	run_lib check_download_tools
	assert_eq "wget used when curl missing" "wget" "$out"

	remove_tool wget
	run_lib check_download_tools
	assert_rc "no tool exits 1" 1
	assert_contains "no tool message" "$err" "No download tool found"
	assert_eq "no tool prints nothing on stdout" "" "$out"
}

test_unit_create_sha256() {
	printf 'abc' > "$sb/payload"
	run_lib create_sha256 "$sb/payload"
	assert_eq "sha256sum digest" "$abc_sha" "$out"

	run_lib create_sha256 "$sb/missing"
	assert_rc "missing file returns 1" 1
	assert_contains "missing file message" "$err" "File not found for checksum"

	local real_sha
	real_sha="$(command -v sha256sum)"
	remove_tool sha256sum
	make_shim shasum << EOF
[[ \$1 == -a && \$2 == 256 ]] || exit 1
exec "$real_sha" "\$3"
EOF
	run_lib create_sha256 "$sb/payload"
	assert_eq "shasum fallback digest" "$abc_sha" "$out"

	remove_tool shasum
	run_lib create_sha256 "$sb/payload"
	assert_rc "no sha tool returns 1" 1
	assert_contains "no sha tool message" "$err" "No SHA256 tool found"
}

test_unit_check_gh_cli() {
	run_lib check_gh_cli
	assert_rc "gh absent" 1
	add_gh
	run_lib check_gh_cli
	assert_rc "gh present" 0
}

test_unit_print_output_goes_to_stderr() {
	local fn
	for fn in print_info print_action print_warning print_error print_success print_failure print_generic; do
		run_lib "$fn" "hello world"
		assert_eq "$fn leaves stdout clean" "" "$out"
		assert_contains "$fn prints message to stderr" "$err" "hello world"
	done
}

test_unit_print_output_formatting() {
	run_lib print_info "Key: some value"
	assert_contains "colon messages keep prefix and suffix" "$err" "Key: some value"
	run_lib print_info "100% done"
	assert_contains "percent signs are not treated as format" "$err" "100% done"
	run_lib print_info "no colon here"
	assert_contains "messages without colon" "$err" "no colon here"
}

test_unit_handle_error() {
	run_lib handle_error 0 "mycmd" "some context"
	assert_rc "zero exit code is a no-op" 0
	assert_eq "no-op prints nothing" "" "$err"

	run_lib handle_error 7 "mycmd --flag" "some context"
	assert_rc "propagates the failing exit code" 7
	assert_contains "names the command" "$err" "Command failed: mycmd --flag"
	assert_contains "shows context" "$err" "Context: some context"
	assert_contains "shows exit code" "$err" "Exit code: 7"
}

test_unit_check_supported_distro() {
	local entry content expected
	local cases=(
		'ID=alpine|0'
		'ID=debian|0'
		'ID=ubuntu\nID_LIKE=debian|0'
		'ID=linuxmint\nID_LIKE="ubuntu debian"|0'
		'ID=fedora\nID_LIKE="rhel fedora"|1'
		'ID=arch|1'
		'ID=debianx|1'
		'ID=|1'
	)
	for entry in "${cases[@]}"; do
		content="${entry%|*}"
		expected="${entry##*|}"
		set_os_release "$content\n"
		run_lib check_supported_distro
		assert_rc "os-release [$content]" "$expected"
	done

	set_os_release 'ID=fedora\n'
	run_lib check_supported_distro
	assert_contains "unsupported message names the distro" "$err" "Unsupported distribution: fedora"

	rm -f "$sb/os-release"
	run_lib check_supported_distro
	assert_rc "missing os-release exits 1" 1
	assert_contains "missing os-release message" "$err" "Cannot determine distribution"
}

# ── get_release_tag ──

test_unit_get_release_tag_versions() {
	local pair
	for pair in 1.2:$tag_12 v1:$tag_12 v1.2:$tag_12 2.0:$tag_20 v2.0:$tag_20 2.1:$tag_21 v2:$tag_21 v2.1:$tag_21; do
		qi_env=("LIBTORRENT_VERSION=${pair%%:*}")
		run_lib get_release_tag
		assert_eq "tag for ${pair%%:*}" "${pair#*:} 0" "$out"
		assert_eq "no stderr noise for ${pair%%:*}" "" "$err"
	done
}

test_unit_get_release_tag_default_is_v2() {
	run_lib get_release_tag
	assert_eq "default maps to libtorrent 2.1" "$tag_21 0" "$out"
	qi_env=("LIBTORRENT_VERSION=v2")
	run_lib get_release_tag
	assert_eq "v2 maps to libtorrent 2.1" "$tag_21 0" "$out"
}

test_unit_get_release_tag_with_wget() {
	remove_tool curl
	add_wget
	qi_env=("LIBTORRENT_VERSION=2.1")
	run_lib get_release_tag
	assert_eq "wget path returns same tag" "$tag_21 0" "$out"
	assert_called "wget was used" "wget https://github.com/userdocs/qbittorrent-nox-static/releases/latest/download/dependency-version.json"
}

test_unit_get_release_tag_invalid_version() {
	local ver
	for ver in 2 2.1.2 latest 1_2 v3 3.0 v2.2 1.1 V2; do
		qi_env=("LIBTORRENT_VERSION=$ver")
		run_lib get_release_tag
		assert_rc "rejects [$ver]" 1
		assert_contains "message for [$ver]" "$err" "Invalid LibTorrent version: $ver"
		assert_eq "stdout empty for [$ver]" "" "$out"
	done
}

test_unit_get_release_tag_missing_keys() {
	write_release_json libtorrent_2_1
	qi_env=("LIBTORRENT_VERSION=2.1")
	run_lib get_release_tag
	assert_rc "missing libtorrent key" 1
	assert_contains "reports parse failure" "$err" "Failed to parse version information"
	assert_contains "reports missing libtorrent" "$err" "LibTorrent version: not found"

	# A different libtorrent key still resolves when only 2.1 is absent
	qi_env=("LIBTORRENT_VERSION=2.0")
	run_lib get_release_tag
	assert_rc "other versions unaffected" 0

	write_release_json qbittorrent
	run_lib get_release_tag
	assert_rc "missing qbittorrent key" 1
	assert_contains "reports missing qbittorrent" "$err" "qBittorrent version: not found"
}

test_unit_get_release_tag_revision() {
	release_revision=7
	write_release_json
	run_lib get_release_tag
	assert_eq "revision is returned" "$tag_21 7" "$out"

	write_release_json revision
	run_lib get_release_tag
	assert_rc "missing revision is not fatal" 0
	assert_eq "stdout holds only the tag" "$tag_21 " "$out"
	assert_contains "warns about the revision" "$err" "Failed to parse revision"
}

test_unit_get_release_tag_fetch_failures() {
	: > "$sb/mock/release.json"
	run_lib get_release_tag
	assert_rc "empty response exits 1" 1
	assert_contains "empty response message" "$err" "empty response"

	touch "$sb/mock/fail_release"
	run_lib get_release_tag
	assert_rc_nonzero "curl failure is fatal"
	assert_contains "curl failure message" "$err" "Failed to fetch release information"

	remove_tool curl
	add_wget
	run_lib get_release_tag
	assert_rc_nonzero "wget failure is fatal"
	assert_contains "wget failure message" "$err" "Failed to fetch release information"
}

test_unit_get_release_tag_no_tool() {
	remove_tool curl
	run_lib get_release_tag
	assert_rc "no download tool" 1
	assert_contains "no download tool message" "$err" "No download tool found"
}

# ── download ──

test_unit_download() {
	run_lib download "$release_base/$tag_20/x86_64-qbittorrent-nox" "$sb/dl"
	assert_rc "curl download succeeds" 0
	assert_same_file "payload matches" "$sb/dl" "$sb/mock/binary"

	rm -f "$sb/dl"
	remove_tool curl
	add_wget
	run_lib download "$release_base/$tag_20/x86_64-qbittorrent-nox" "$sb/dl"
	assert_rc "wget download succeeds" 0
	assert_same_file "wget payload matches" "$sb/dl" "$sb/mock/binary"

	touch "$sb/mock/fail_download"
	run_lib download "$release_base/$tag_20/x86_64-qbittorrent-nox" "$sb/dl2"
	assert_rc_nonzero "wget download failure is fatal"
	assert_contains "download failure message" "$err" "Failed to download binary"

	rm -f "$sb/mock/fail_download" "$sb/dl2"
	touch "$sb/mock/empty_download"
	run_lib download "$release_base/$tag_20/x86_64-qbittorrent-nox" "$sb/dl2"
	assert_rc "empty download is fatal" 1
	assert_contains "empty download message" "$err" "Download failed or file is empty"
}

# ── verify_binary_integrity ──

verify_payload() {
	printf 'abc' > "$sb/payload"
	run_lib verify_binary_integrity "$sb/payload" "$tag_21" x86_64
}

test_unit_verify_api_match() {
	write_api_json "$abc_sha"
	verify_payload
	assert_rc "matching digest" 0
	assert_contains "prints local sha" "$err" "SHA256: $abc_sha"
	assert_contains "reports API pass" "$err" "GitHub API SHA256 verification passed"
	assert_called "queries the release by tag" "https://api.github.com/repos/userdocs/qbittorrent-nox-static/releases/tags/$tag_21"
}

test_unit_verify_matches_any_asset() {
	write_api_json "$fake_sha" "$abc_sha" "$fake_sha"
	verify_payload
	assert_rc "match in the middle of several assets" 0
}

test_unit_verify_compact_json() {
	write_api_json_compact "$abc_sha" "$fake_sha" "$fake_sha"
	verify_payload
	assert_rc "match as first digest in single-line JSON" 0
	write_api_json_compact "$fake_sha" "$fake_sha" "$abc_sha"
	verify_payload
	assert_rc "match as last digest in single-line JSON" 0
}

test_unit_verify_mismatch() {
	write_api_json "$fake_sha"
	verify_payload
	assert_rc "mismatch returns 2" 2
	assert_contains "reports failure" "$err" "GitHub API SHA256 verification failed"
	assert_contains "lists the API digest" "$err" "$fake_sha"
}

test_unit_verify_unverifiable() {
	write_api_json
	verify_payload
	assert_rc "no digests returns 1" 1
	assert_contains "no digests message" "$err" "No SHA256 digests found"

	: > "$sb/mock/api.json"
	verify_payload
	assert_rc "empty API response returns 1" 1
	assert_contains "empty API message" "$err" "Empty response from GitHub API"

	touch "$sb/mock/fail_api"
	verify_payload
	assert_rc "API failure returns 1" 1
	assert_contains "API failure message" "$err" "Failed to fetch release information from GitHub API"
}

test_unit_verify_no_sha_tool() {
	remove_tool sha256sum
	verify_payload
	assert_rc "no sha tool returns 1" 1
	assert_contains "no sha tool message" "$err" "Could not calculate local SHA256"
	assert_not_called "API is not queried" "api.github.com"
}

test_unit_verify_gh_attestation() {
	add_gh
	write_api_json "$fake_sha"
	verify_payload
	assert_rc "attestation success short-circuits" 0
	assert_contains "reports attestation pass" "$err" "GitHub CLI attestation verification passed"
	assert_called "gh targets the right repo" "--repo userdocs/qbittorrent-nox-static"
	assert_called "gh verifies the file" "gh attestation verify $sb/payload"
	assert_not_called "API is skipped when attestation passes" "api.github.com"
}

test_unit_verify_gh_fallback() {
	add_gh
	touch "$sb/mock/gh_fail"
	write_api_json "$abc_sha"
	verify_payload
	assert_rc "falls back to API when attestation fails" 0
	assert_contains "mentions fallback" "$err" "Falling back to GitHub API verification"

	write_api_json "$fake_sha"
	verify_payload
	assert_rc "attestation failure plus mismatch" 2
}

test_unit_verify_with_wget() {
	remove_tool curl
	add_wget
	write_api_json "$abc_sha"
	verify_payload
	assert_rc "wget API verification" 0
	assert_called "wget queried the API" "wget https://api.github.com/"
}

test_unit_verify_with_jq() {
	add_real_tool jq || {
		skip_reason="jq not installed"
		return
	}
	write_api_json "$fake_sha" "$abc_sha"
	verify_payload
	assert_rc "jq path match" 0
	write_api_json_compact "$fake_sha"
	verify_payload
	assert_rc "jq path mismatch" 2
}

test_unit_verify_github_actions_hint() {
	qi_env=("GITHUB_ACTIONS=true")
	write_api_json "$abc_sha"
	verify_payload
	assert_contains "explains missing gh in Actions" "$err" "GitHub Actions detected but gh CLI not found"
}

# ══════════════════════════════════════════════════════════════════════════════
# Integration tests (full script runs)
# ══════════════════════════════════════════════════════════════════════════════

test_cli_help() {
	local flag
	for flag in -h --help; do
		run_qi "$flag"
		assert_rc "$flag exits 0" 0
		assert_contains "$flag shows usage" "$out" "Usage: qi.bash"
		assert_contains "$flag documents 1.2" "$out" "1.2"
		assert_contains "$flag documents 2.0" "$out" "2.0"
		assert_contains "$flag documents 2.1" "$out" "2.1"
		assert_contains "$flag documents --libtorrent" "$out" "--libtorrent"
		assert_contains "$flag documents --force-arch" "$out" "--force-arch"
		assert_eq "$flag makes no network calls" "" "$(calls_log)"
	done
	run_qi -lt 2.1 -fa armv7 --help
	assert_rc "help after valid options" 0
}

test_cli_unknown_option() {
	run_qi --bogus
	assert_rc "unknown flag exits 1" 1
	assert_contains "unknown flag message" "$err" "Unknown option: --bogus"
	run_qi stray
	assert_rc "stray argument exits 1" 1
	assert_eq "no calls made" "" "$(calls_log)"
}

test_cli_libtorrent_validation() {
	local ver
	for ver in 3.0 v3 2 latest ""; do
		run_qi -lt "$ver"
		assert_rc "-lt [$ver] exits 1" 1
		assert_contains "-lt [$ver] message" "$err" "Invalid libtorrent version"
	done
	run_qi -lt
	assert_rc "-lt without value exits 1" 1
	assert_eq "no downloads on invalid -lt" "" "$(bin_listing)"
}

test_cli_libtorrent_selection() {
	local pair ver tag
	for pair in 1.2:$tag_12 v1:$tag_12 v1.2:$tag_12 2.0:$tag_20 v2.0:$tag_20 2.1:$tag_21 v2:$tag_21 v2.1:$tag_21; do
		ver="${pair%%:*}"
		tag="${pair#*:}"
		rm -rf "$sb/home/bin"
		: > "$sb/mock/calls.log"
		run_qi -lt "$ver"
		assert_rc "-lt $ver exits 0" 0
		assert_called "-lt $ver downloads $tag" "curl $release_base/$tag/x86_64-qbittorrent-nox"
	done
	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	run_qi --libtorrent 2.1
	assert_called "--libtorrent long form" "curl $release_base/$tag_21/x86_64-qbittorrent-nox"
}

test_cli_libtorrent_env_and_precedence() {
	qi_env=("LIBTORRENT_VERSION=1.2")
	run_qi
	assert_called "env selects 1.2" "$tag_12/x86_64-qbittorrent-nox"

	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	run_qi -lt 2.0
	assert_called "flag overrides env" "$tag_20/x86_64-qbittorrent-nox"
	assert_not_called "env value unused" "$tag_12"

	: > "$sb/mock/calls.log"
	qi_env=()
	rm -rf "$sb/home/bin"
	run_qi
	assert_called "default is libtorrent 2.1" "$tag_21/x86_64-qbittorrent-nox"
}

test_cli_invalid_env_libtorrent_aborts() {
	qi_env=("LIBTORRENT_VERSION=9")
	run_qi
	assert_rc "invalid env exits 1" 1
	assert_contains "reports invalid version" "$err" "Invalid LibTorrent version: 9"
	assert_not_called "never attempts a binary download" "-qbittorrent-nox"
	assert_eq "nothing installed" "" "$(bin_listing)"
	assert_not_contains "no bogus empty-tag URL" "$(calls_log)" "download//"
}

test_cli_force_arch() {
	local arch
	for arch in x86_64 x86 aarch64 armv7 armhf riscv64; do
		rm -rf "$sb/home/bin"
		: > "$sb/mock/calls.log"
		run_qi -fa "$arch"
		assert_rc "-fa $arch exits 0" 0
		assert_called "-fa $arch URL" "$tag_21/$arch-qbittorrent-nox"
	done
	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	run_qi --force-arch aarch64
	assert_called "--force-arch long form" "aarch64-qbittorrent-nox"
}

test_cli_force_arch_validation() {
	run_qi -fa bogus
	assert_rc "-fa bogus exits 1" 1
	assert_contains "-fa bogus message" "$err" "Unsupported architecture: bogus"

	run_qi -fa
	assert_rc "-fa without value exits 1" 1
	assert_contains "-fa without value message" "$err" "requires an architecture"

	qi_env=("FORCE_ARCH=bogus")
	run_qi
	assert_rc "FORCE_ARCH=bogus exits 1" 1
	assert_contains "FORCE_ARCH=bogus message" "$err" "Unsupported architecture: bogus"
	assert_not_called "no download for invalid arch" "-qbittorrent-nox"
}

test_cli_force_arch_env() {
	qi_env=("FORCE_ARCH=riscv64")
	run_qi
	assert_rc "FORCE_ARCH env exits 0" 0
	assert_called "FORCE_ARCH env URL" "riscv64-qbittorrent-nox"

	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	run_qi -fa armv7
	assert_called "flag overrides FORCE_ARCH" "armv7-qbittorrent-nox"

	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	qi_env=("FORCE_ARCH=")
	run_qi
	assert_called "empty FORCE_ARCH falls back to detection" "x86_64-qbittorrent-nox"
}

test_install_arch_detection() {
	local pair
	for pair in amd64:x86_64 arm64:aarch64 armhf:armv7 i386:x86 riscv64:riscv64; do
		set_arch dpkg "${pair%%:*}"
		rm -rf "$sb/home/bin"
		: > "$sb/mock/calls.log"
		run_qi
		assert_called "dpkg ${pair%%:*} downloads ${pair#*:}" "$tag_21/${pair#*:}-qbittorrent-nox"
	done

	remove_tool dpkg
	set_os_release 'ID=alpine\n'
	set_arch apk armhf
	rm -rf "$sb/home/bin"
	: > "$sb/mock/calls.log"
	run_qi
	assert_rc "alpine armhf exits 0" 0
	assert_called "alpine armhf keeps armhf binary" "$tag_21/armhf-qbittorrent-nox"
}

test_install_undetectable_arch_aborts() {
	set_arch dpkg s390x
	run_qi
	assert_rc "unsupported detected arch exits 1" 1
	assert_contains "names the arch" "$err" "Unsupported architecture: s390x"
	assert_not_called "no release lookup" "dependency-version.json"
	assert_not_called "no binary download" "-qbittorrent-nox"
	assert_eq "nothing installed" "" "$(bin_listing)"

	remove_tool dpkg
	run_qi
	assert_rc "no detection tool exits 1" 1
	assert_not_called "no downloads without detection" "-qbittorrent-nox"
}

test_install_success() {
	run_qi
	assert_rc "exits 0" 0
	assert_eq "stdout is empty (all messages on stderr)" "" "$out"
	assert_file "binary installed" "$sb/home/bin/qbittorrent-nox"
	assert_executable "binary is executable" "$sb/home/bin/qbittorrent-nox"
	assert_same_file "content matches download" "$sb/home/bin/qbittorrent-nox" "$sb/mock/binary"
	assert_eq "no temp files left behind" "qbittorrent-nox" "$(bin_listing)"
	assert_contains "reports arch" "$err" "Architecture: x86_64"
	assert_contains "reports resolved libtorrent version" "$err" "LibTorrent version: 2.1.2"
	assert_not_contains "does not echo the raw alias" "$err" "LibTorrent version: v2"
	assert_contains "reports revision" "$err" "Build revision: 0"
	assert_contains "reports verification" "$err" "GitHub API SHA256 verification passed"
	assert_contains "reports binary version" "$err" "Version: qBittorrent v9.9.9"
	assert_contains "reports success" "$err" "Installation completed successfully!"
}

test_install_shows_resolved_libtorrent_version() {
	local pair
	for pair in v1:1.2.20 1.2:1.2.20 v2.0:2.0.15 2.0:2.0.15 v2:2.1.2 2.1:2.1.2; do
		rm -rf "$sb/home/bin"
		run_qi -lt "${pair%%:*}"
		assert_contains "-lt ${pair%%:*} shows ${pair#*:}" "$err" "LibTorrent version: ${pair#*:}"
	done
}

test_install_creates_bin_dir() {
	assert_no_file "bin dir absent beforehand" "$sb/home/bin"
	run_qi
	assert_rc "exits 0" 0
	assert_file "bin dir created and populated" "$sb/home/bin/qbittorrent-nox"
}

test_install_replaces_existing() {
	seed_existing
	run_qi
	assert_rc "exits 0" 0
	assert_same_file "old binary replaced" "$sb/home/bin/qbittorrent-nox" "$sb/mock/binary"
	assert_eq "no temp files left behind" "qbittorrent-nox" "$(bin_listing)"
}

test_install_idempotent() {
	run_qi
	run_qi
	assert_rc "second run exits 0" 0
	assert_eq "still a single file" "qbittorrent-nox" "$(bin_listing)"
}

test_install_with_wget() {
	remove_tool curl
	add_wget
	run_qi
	assert_rc "exits 0" 0
	assert_same_file "installed via wget" "$sb/home/bin/qbittorrent-nox" "$sb/mock/binary"
	assert_not_called "curl never used" "curl "
	assert_called "wget downloaded the binary" "wget $release_base/$tag_21/x86_64-qbittorrent-nox"
}

test_install_no_download_tool() {
	remove_tool curl
	run_qi
	assert_rc "exits 1" 1
	assert_contains "explains the problem" "$err" "No download tool found"
	assert_eq "nothing installed" "" "$(bin_listing)"
}

test_install_supported_distros() {
	local content
	for content in 'ID=alpine\n' 'ID=debian\n' 'ID=ubuntu\nID_LIKE=debian\n'; do
		set_os_release "$content"
		rm -rf "$sb/home/bin"
		run_qi
		assert_rc "installs on [$content]" 0
	done
}

test_install_unsupported_distro() {
	set_os_release 'ID=fedora\nID_LIKE="rhel fedora"\n'
	run_qi
	assert_rc "exits 1" 1
	assert_contains "explains the problem" "$err" "Unsupported distribution"
	assert_eq "no network calls" "" "$(calls_log)"

	rm -f "$sb/os-release"
	run_qi
	assert_rc "missing os-release exits 1" 1
	assert_contains "explains missing file" "$err" "Cannot determine distribution"
}

test_install_release_json_problems() {
	touch "$sb/mock/fail_release"
	run_qi
	assert_rc_nonzero "release fetch failure is fatal"
	assert_not_called "no binary download" "-qbittorrent-nox"
	assert_eq "nothing installed" "" "$(bin_listing)"

	rm -f "$sb/mock/fail_release"
	write_release_json libtorrent_2_1
	run_qi -lt 2.1
	assert_rc "missing libtorrent key is fatal" 1
	assert_contains "parse failure message" "$err" "Failed to parse version information"
	assert_not_called "no binary download for missing key" "-qbittorrent-nox"
}

test_install_revision_handling() {
	release_revision=3
	write_release_json
	run_qi
	assert_contains "shows revision 3" "$err" "Build revision: 3"

	rm -rf "$sb/home/bin"
	write_release_json revision
	run_qi
	assert_rc "missing revision is not fatal" 0
	assert_not_contains "no revision line" "$err" "Build revision"
}

test_install_failed_download_keeps_existing() {
	seed_existing
	touch "$sb/mock/fail_download"
	run_qi
	assert_rc_nonzero "download failure is fatal"
	assert_contains "failure message" "$err" "Failed to download binary"
	assert_eq "existing binary untouched" "old-binary" "$(< "$sb/home/bin/qbittorrent-nox")"
	assert_eq "partial download cleaned up" "qbittorrent-nox" "$(bin_listing)"
}

test_install_empty_download_keeps_existing() {
	seed_existing
	touch "$sb/mock/empty_download"
	run_qi
	assert_rc "empty download exits 1" 1
	assert_contains "failure message" "$err" "Download failed or file is empty"
	assert_eq "existing binary untouched" "old-binary" "$(< "$sb/home/bin/qbittorrent-nox")"
	assert_eq "temp file cleaned up" "qbittorrent-nox" "$(bin_listing)"
}

test_install_checksum_mismatch_refuses() {
	seed_existing
	write_api_json "$fake_sha"
	run_qi
	assert_rc "mismatch exits 1" 1
	assert_contains "mismatch message" "$err" "Checksum mismatch: refusing to install"
	assert_eq "existing binary untouched" "old-binary" "$(< "$sb/home/bin/qbittorrent-nox")"
	assert_eq "temp file cleaned up" "qbittorrent-nox" "$(bin_listing)"
	assert_not_contains "no success message" "$err" "Installation complete"
}

test_install_checksum_mismatch_fresh() {
	write_api_json "$fake_sha"
	run_qi
	assert_rc "mismatch exits 1" 1
	assert_eq "nothing installed" "" "$(bin_listing)"
}

test_install_unverifiable_still_installs() {
	touch "$sb/mock/fail_api"
	run_qi
	assert_rc "API outage is not fatal" 0
	assert_same_file "binary installed" "$sb/home/bin/qbittorrent-nox" "$sb/mock/binary"
	assert_contains "warns integrity unverified" "$err" "Integrity could not be verified"
	assert_contains "reports errors in summary" "$err" "Installation completed with errors!"
	assert_not_contains "no success summary" "$err" "Installation completed successfully!"

	rm -rf "$sb/home/bin" "$sb/mock/fail_api"
	write_api_json
	run_qi
	assert_rc "no published digests is not fatal" 0
	assert_contains "warns integrity unverified (no digests)" "$err" "Integrity could not be verified"
}

test_install_no_sha_tool_still_installs() {
	remove_tool sha256sum
	run_qi
	assert_rc "missing sha tool is not fatal" 0
	assert_file "binary installed" "$sb/home/bin/qbittorrent-nox"
	assert_contains "warns integrity unverified" "$err" "Integrity could not be verified"
}

test_install_gh_attestation_checks_download_before_install() {
	add_gh
	run_qi
	assert_rc "exits 0" 0
	assert_contains "attestation passed" "$err" "GitHub CLI attestation verification passed"
	assert_called "gh checked the temp file" "gh attestation verify $sb/home/bin/.qbittorrent-nox."
	assert_not_called "API skipped" "api.github.com"
	assert_contains "attestation shown as enabled" "$err" "Attestation verification: enabled"
}

test_install_gh_failure_falls_back_to_api() {
	add_gh
	touch "$sb/mock/gh_fail"
	run_qi
	assert_rc "exits 0" 0
	assert_called "API consulted" "api.github.com"
	assert_contains "API verification passed" "$err" "GitHub API SHA256 verification passed"
}

test_install_gh_failure_and_mismatch_refuses() {
	add_gh
	touch "$sb/mock/gh_fail"
	write_api_json "$fake_sha"
	run_qi
	assert_rc "exits 1" 1
	assert_eq "nothing installed" "" "$(bin_listing)"
}

test_install_without_gh_reports_disabled() {
	run_qi
	assert_contains "attestation disabled" "$err" "Attestation verification: disabled"
}

test_install_broken_binary_warns() {
	set_binary broken
	run_qi
	assert_rc "broken binary does not fail the install" 0
	assert_file "binary still installed" "$sb/home/bin/qbittorrent-nox"
	assert_contains "reports test failure" "$err" "Binary test failed"
	assert_contains "suggests ldd" "$err" "ldd"
	assert_contains "summary reports errors" "$err" "Installation completed with errors!"
}

test_install_exec_format_error_hint() {
	set_binary execformat
	run_qi
	assert_rc "wrong-arch binary does not fail the install" 0
	assert_contains "detects architecture mismatch" "$err" "Architecture mismatch detected"
	assert_contains "suggests qemu" "$err" "qemu-user-static"
}

test_install_path_warning() {
	run_qi
	assert_contains "warns when bin dir not in PATH" "$err" "is not in your PATH"

	rm -rf "$sb/home/bin"
	qi_path="$sb/shim:$sb/tools:$sb/home/bin"
	run_qi
	assert_not_contains "silent when bin dir is in PATH" "$err" "is not in your PATH"
}

test_install_unwritable_bin_dir() {
	mkdir -p "$sb/home/bin"
	chmod a-w "$sb/home/bin"
	if [[ -w "$sb/home/bin" ]]; then
		chmod u+w "$sb/home/bin"
		skip_reason="running with privileges that ignore directory permissions"
		return
	fi
	run_qi
	chmod u+w "$sb/home/bin"
	assert_rc_nonzero "unwritable bin dir is fatal"
	assert_contains "reports temp file failure" "$err" "Failed to create temporary file"
	assert_eq "nothing written" "" "$(bin_listing)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Runner
# ══════════════════════════════════════════════════════════════════════════════

run_all() {
	local filter="${1:-}" name status

	for name in $(compgen -A function test_); do
		[[ -n $filter && $name != *"$filter"* ]] && continue
		new_sandbox
		assertions=0
		failures=()
		((total_tests++))

		"$name"

		if [[ -n $skip_reason ]]; then
			((skipped_tests++))
			status="SKIP"
			printf '  [%s] %s (%s)\n' "$status" "$name" "$skip_reason"
		elif ((${#failures[@]} > 0)); then
			((failed_tests++))
			failed_names+=("$name")
			printf '  [FAIL] %s (%d/%d assertions failed)\n' "$name" "${#failures[@]}" "$assertions"
			printf '%s\n' "${failures[@]}"
		elif ((assertions == 0)); then
			((failed_tests++))
			failed_names+=("$name")
			printf '  [FAIL] %s (no assertions ran)\n' "$name"
		else
			((passed_tests++))
			printf '  [ ok ] %s (%d assertions)\n' "$name" "$assertions"
		fi
	done

	printf '\nTests: %d, passed: %d, failed: %d, skipped: %d\n' "$total_tests" "$passed_tests" "$failed_tests" "$skipped_tests"
	if ((failed_tests > 0)); then
		printf 'Failed: %s\n' "${failed_names[*]}"
		return 1
	fi
	if ((total_tests == 0)); then
		printf 'No tests matched filter: %s\n' "$filter"
		return 1
	fi
}

if [[ ! -f $qi_src ]]; then
	printf 'qi.bash not found next to %s\n' "${BASH_SOURCE[0]}" >&2
	exit 1
fi

run_all "$@"
