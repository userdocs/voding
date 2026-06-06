#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
simple_source="$script_dir/../simple_source"

# Colors
red='\e[31m'
green='\e[32m'
cyan='\e[36m'
end='\e[0m'
bold='\e[1m'

total_tests=0
passed_tests=0
failed_tests=0

# Isolated tmp dir for mock curl; cleaned up on exit regardless of outcome
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ── Assertion helpers ─────────────────────────────────────────────────────────

_pass() {
	printf '  %b✓ PASS%b\n' "$green" "$end"
	((passed_tests++))
}

_fail() {
	printf '  %bFAIL: %s%b\n' "$red" "$1" "$end"
	if [[ -n ${2:-} ]]; then
		printf '  Actual output:\n'
		printf '%s' "$2" | tail -5 | sed 's/^/    /'
	fi
	((failed_tests++))
}

# run_test <name> <expected_exit> <cmd> [args...]
run_test() {
	local name="$1"
	local expected_exit="$2"
	shift 2
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	local out
	out=$(PATH="$tmp_dir:$PATH" "$@" 2>&1)
	local actual_exit=$?
	if [[ $actual_exit -eq $expected_exit ]]; then
		_pass
	else
		_fail "expected exit $expected_exit, got $actual_exit"
		if [[ -n $out ]]; then
			printf '  Last output:\n'
			printf '%s' "$out" | tail -3 | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'
		fi
	fi
}

# assert_output <name> <grep_pattern> <cmd> [args...]
assert_output() {
	local name="$1"
	local pattern="$2"
	shift 2
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	local out
	out=$(PATH="$tmp_dir:$PATH" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
	if printf '%s' "$out" | grep -q "$pattern"; then
		_pass
	else
		_fail "output did not contain: $pattern" "$out"
	fi
}

# assert_not_output <name> <grep_pattern> <cmd> [args...]
assert_not_output() {
	local name="$1"
	local pattern="$2"
	shift 2
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	local out
	out=$(PATH="$tmp_dir:$PATH" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
	if printf '%s' "$out" | grep -q "$pattern"; then
		_fail "output unexpectedly contained: $pattern" "$out"
	else
		_pass
	fi
}

section() {
	printf '\n%b%b── %s %b\n' "$bold" "$cyan" "$1" "$end"
}

# ── Mock curl ─────────────────────────────────────────────────────────────────
# Written into $tmp_dir (not $script_dir) so trap cleanup handles it.
# Speeds:  ftp.gnu.org=150, ftpmirror.gnu.org=80, dotsrc.org=300,
#          ftp.snt.utwente.nl=500 (fastest), mirrors.kernel.org=unavailable

cat > "$tmp_dir/curl" << 'EOF'
#!/bin/bash
args="$*"
case "$args" in
	*"sourceware.org/pub/gcc/releases"*)
		printf '<a href="gcc-13.2.0/">gcc-13.2.0/</a>\n<a href="gcc-14.1.0/">gcc-14.1.0/</a>\n'
		exit 0
		;;
	*"sourceware.org/pub/binutils/releases"*)
		printf '<a href="binutils-2.42.tar.xz">binutils-2.42.tar.xz</a>\n<a href="binutils-2.43.tar.xz">binutils-2.43.tar.xz</a>\n'
		exit 0
		;;
	*"mirrorservice.org"*)
		exit 1
		;;
	*"--range"*"0-65535"*)
		# Speed test responses (bytes/sec as float)
		if   [[ "$args" =~ ftp\.gnu\.org ]];            then printf '153600.000000'
		elif [[ "$args" =~ ftpmirror\.gnu\.org ]];      then printf '81920.000000'
		elif [[ "$args" =~ mirrors\.dotsrc\.org ]];     then printf '307200.000000'
		elif [[ "$args" =~ ftp\.snt\.utwente\.nl ]];    then printf '512000.000000'
		else printf '0'
		fi
		exit 0
		;;
	*"%{http_code}"*|*"-I"*)
		# http_ok checks — only listed mirrors return 200; kernel.org is absent
		if [[ "$args" =~ (ftp\.gnu\.org|ftpmirror\.gnu\.org|mirrors\.dotsrc\.org|ftp\.snt\.utwente\.nl) ]]; then
			printf '200'
		else
			printf '404'
		fi
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
chmod +x "$tmp_dir/curl"

# ── Tests ─────────────────────────────────────────────────────────────────────

printf '%b%bSIMPLE_SOURCE TEST SUITE%b\n' "$bold" "$cyan" "$end"
printf 'Script: %s\n' "$simple_source"

section "Version Discovery"

assert_output "GCC version returned" "14\.1\.0" \
	"$simple_source" gcc

assert_output "Binutils version returned" "2\.43" \
	"$simple_source" binutils

assert_output "Both versions, gcc first" "14\.1\.0" \
	"$simple_source" gcc binutils

assert_output "Both versions, binutils second" "2\.43" \
	"$simple_source" gcc binutils

# Version output must be bare (e.g. 14.1.0, not gcc-14.1.0)
assert_not_output "GCC output has no 'gcc-' prefix" "^gcc-" \
	"$simple_source" gcc

assert_not_output "Binutils output has no 'binutils-' prefix" "^binutils-" \
	"$simple_source" binutils

section "Mirror Selection"

# ftp.snt.utwente.nl has the highest mock speed (512000 bytes/sec = 500 KB/s)
assert_output "Fastest mirror selected (ftp.snt.utwente.nl)" "ftp.snt.utwente.nl" \
	"$simple_source"

# Preferred mirror: if valid and available, it should be used and returned
assert_output "Preferred mirror accepted when accessible" "ftp.gnu.org" \
	"$simple_source" "https://ftp.gnu.org/gnu"

# URL not starting with http/https is treated as an unknown version token → exit 3
run_test "Non-URL argument exits 3" 3 \
	"$simple_source" "not-a-url"

run_test "Non-http scheme exits 3" 3 \
	"$simple_source" "ftp://ftp.gnu.org/gnu"

section "CLI / Flags"

run_test "Invalid argument exits 3" 3 \
	"$simple_source" invalid_token

# -v enables INFO output (goes to stderr)
assert_output "-v flag enables INFO messages" "\[INFO\]" \
	"$simple_source" -v

# -vv enables DEBUG output
assert_output "-vv flag enables DEBUG messages" "\[DEBUG\]" \
	"$simple_source" -vv

# Without -v there must be no [INFO] or [DEBUG] lines
assert_not_output "No INFO output without -v" "\[INFO\]" \
	"$simple_source"

assert_not_output "No DEBUG output without -vv" "\[DEBUG\]" \
	"$simple_source"

# -v with a version query should not suppress the version output
assert_output "-v with gcc still outputs version" "14\.1\.0" \
	"$simple_source" -v gcc

section "Exit Codes (network-error propagation)"

# Simulate total network failure: curl always fails
cat > "$tmp_dir/curl" << 'FAILEOF'
#!/bin/bash
exit 1
FAILEOF
chmod +x "$tmp_dir/curl"

run_test "Network failure on version fetch exits 2" 2 \
	"$simple_source" gcc

run_test "Network failure on mirror find exits 2" 2 \
	"$simple_source"

# Restore working mock for any further tests
cat > "$tmp_dir/curl" << 'EOF'
#!/bin/bash
args="$*"
case "$args" in
	*"sourceware.org/pub/gcc/releases"*)
		printf '<a href="gcc-14.1.0/">gcc-14.1.0/</a>\n'
		exit 0
		;;
	*"sourceware.org/pub/binutils/releases"*)
		printf '<a href="binutils-2.43.tar.xz">binutils-2.43.tar.xz</a>\n'
		exit 0
		;;
	*"mirrorservice.org"*) exit 1 ;;
	*"--range"*"0-65535"*) printf '102400.000000'; exit 0 ;;
	*"%{http_code}"*|*"-I"*)
		if [[ "$*" =~ ftp\.gnu\.org ]]; then printf '200'; else printf '404'; fi
		exit 0
		;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp_dir/curl"

section "Speed Rounding"

# Confirm speed_kb calculation is non-zero for a valid mirror
assert_output "Mirror output is non-empty after speed test" "ftp.gnu.org" \
	"$simple_source"

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n%b%b─────────────────────────────────%b\n' "$bold" "$cyan" "$end"
printf 'Total:  %d\n' "$total_tests"
printf '%bPassed: %d%b\n' "$green" "$passed_tests" "$end"
if [[ $failed_tests -gt 0 ]]; then
	printf '%bFailed: %d%b\n' "$red" "$failed_tests" "$end"
else
	printf 'Failed: 0\n'
fi
printf '%b%b─────────────────────────────────%b\n' "$bold" "$cyan" "$end"

if [[ $failed_tests -eq 0 ]]; then
	printf '%b%bALL TESTS PASSED%b\n\n' "$bold" "$green" "$end"
	exit 0
else
	printf '%b%bSOME TESTS FAILED%b\n\n' "$bold" "$red" "$end"
	exit 1
fi
