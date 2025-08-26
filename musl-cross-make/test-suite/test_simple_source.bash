#!/bin/bash

# Test suite for simple_source script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMPLE_SOURCE="$SCRIPT_DIR/../simple_source"

printf '%s\n' "=== SIMPLE_SOURCE TEST SUITE ==="
printf '%s\n' "Testing script: $SIMPLE_SOURCE"

total_tests=0
passed_tests=0

run_test() {
	local test_name="$1"
	local test_cmd="$2"
	local expected_exit="${3:-0}"

	((total_tests++))
	printf '\n[%d] Testing: %s\n' "$total_tests" "$test_name"

	local output
	local actual_exit
	output=$(eval "$test_cmd" 2>&1)
	actual_exit=$?

	if [[ $actual_exit -eq $expected_exit ]]; then
		printf '  ✓ PASS\n'
		((passed_tests++))
	else
		printf '  ✗ FAIL (expected exit %d, got %d)\n' "$expected_exit" "$actual_exit"
		printf '  Output: %s\n' "$output"
	fi
}

run_test_with_output() {
	local test_name="$1"
	local test_cmd="$2"
	local expected_pattern="$3"
	local expected_exit="${4:-0}"

	((total_tests++))
	printf '\n[%d] Testing: %s\n' "$total_tests" "$test_name"

	local output
	local actual_exit
	output=$(eval "$test_cmd" 2>&1)
	actual_exit=$?

	local pass=0
	if [[ $actual_exit -eq $expected_exit ]]; then
		if [[ -n $expected_pattern && $output =~ $expected_pattern ]] || [[ -z $expected_pattern ]]; then
			pass=1
		fi
	fi

	if [[ $pass -eq 1 ]]; then
		printf '  ✓ PASS\n'
		((passed_tests++))
	else
		printf '  ✗ FAIL (expected exit %d, got %d)\n' "$expected_exit" "$actual_exit"
		printf '  Output: %s\n' "$output"
		[[ -n $expected_pattern ]] && printf '  Expected pattern: %s\n' "$expected_pattern"
	fi
}

# Mock curl for offline testing
setup_mock_env() {
	export PATH="$SCRIPT_DIR:$PATH"
	cat > "$SCRIPT_DIR/curl" << 'EOF'
#!/bin/bash
# Mock curl for testing
case "$*" in
	*"sourceware.org/pub/gcc/releases"*)
		printf '<a href="gcc-13.2.0/">gcc-13.2.0/</a>\n<a href="gcc-14.1.0/">gcc-14.1.0/</a>\n'
		exit 0
		;;
	*"sourceware.org/pub/binutils/releases"*)
		printf '<a href="binutils-2.42.tar.xz">binutils-2.42.tar.xz</a>\n<a href="binutils-2.43.tar.xz">binutils-2.43.tar.xz</a>\n'
		exit 0
		;;
	*"-I"*|*"-w"*"%{http_code}"*)
		# Handle HEAD requests and http code requests - return 200 for mirrors and specific files
		if [[ "$*" =~ (ftp\.gnu\.org|ftpmirror\.gnu\.org|mirrors\.dotsrc\.org|ftp\.snt\.utwente\.nl) ]]; then
			if [[ "$*" =~ "-I" ]]; then
				printf 'HTTP/1.1 200 OK\r\n'
			else
				printf '200'
			fi
			exit 0
		fi
		;;
	*"gcc/gcc-14.1.0/gcc-14.1.0.tar.xz"*|*"binutils/binutils-2.43.tar.xz"*)
		if [[ "$*" =~ "-w" ]]; then
			printf '200'
		fi
		exit 0
		;;
	*"--range"*"0-65535"*)
		# Mock speed test - return different speeds for different mirrors
		if [[ "$*" =~ ftp\.gnu\.org ]]; then
			printf '150000.000000'
		elif [[ "$*" =~ ftpmirror\.gnu\.org ]]; then
			printf '80000.000000'
		elif [[ "$*" =~ mirrors\.dotsrc\.org ]]; then
			printf '300000.000000'
		elif [[ "$*" =~ ftp\.snt\.utwente\.nl ]]; then
			printf '500000.000000'
		else
			printf '100000.000000'
		fi
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "$SCRIPT_DIR/curl"
}

cleanup_mock_env() {
	rm -f "$SCRIPT_DIR/curl"
}

# Test version discovery with mocked network
setup_mock_env

# Test 1: GCC version discovery
run_test_with_output "GCC version discovery" "\"$SIMPLE_SOURCE\" gcc" "14\.1\.0"

# Test 2: Binutils version discovery
run_test_with_output "Binutils version discovery" "\"$SIMPLE_SOURCE\" binutils" "2\.43"

# Test 3: Both versions
run_test_with_output "Both versions discovery" "\"$SIMPLE_SOURCE\" gcc binutils" "(14\.1\.0|2\.43)"

# Test 4: Invalid arguments
run_test "Invalid arguments" "\"$SIMPLE_SOURCE\" invalid" 3

# Test 5: No arguments (should find working mirror - returns first available with mock speeds)
run_test_with_output "Mirror discovery (fastest)" "\"$SIMPLE_SOURCE\"" "https://ftp\.gnu\.org/gnu"

# Test 6: Verbose flag - INFO level
run_test_with_output "Verbose INFO level" "\"$SIMPLE_SOURCE\" -v" '\[INFO\].*Testing.*mirrors.*speed'

# Test 7: Verbose flag - DEBUG level
run_test_with_output "Verbose DEBUG level" "\"$SIMPLE_SOURCE\" -vv" '\[DEBUG\].*Discovering.*version.*sourceware'

# Test 8: Verbose with version query
run_test_with_output "Verbose version query" "\"$SIMPLE_SOURCE\" -v gcc binutils" '14\.1\.0.*2\.43'

# Test 9: Speed testing shows selection process
run_test_with_output "Speed-based selection" "\"$SIMPLE_SOURCE\" -v" '\[INFO\].*Selected fastest mirror.*gnu'

# Test 10: URL validation - valid URL
run_test "Valid mirror URL" "\"$SIMPLE_SOURCE\" https://example.com/mirror" 0

# Test 11: URL validation - invalid format
run_test "Invalid URL format" "\"$SIMPLE_SOURCE\" not-a-url" 3

# Test 12: URL validation - complex valid URL
run_test "Complex valid URL" "\"$SIMPLE_SOURCE\" https://ftp.gnu.org/gnu" 0

# Test 13: Verbose flag parsing with URL
run_test_with_output "Verbose with preferred URL" "\"$SIMPLE_SOURCE\" -v https://ftp.gnu.org/gnu" '\[INFO\].*Testing preferred mirror'

cleanup_mock_env

# Test network failure scenarios with broken mock
cat > "$SCRIPT_DIR/curl" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SCRIPT_DIR/curl"
export PATH="$SCRIPT_DIR:$PATH"

# Test 14: Network failure
run_test "Network failure handling" "\"$SIMPLE_SOURCE\" gcc" 1

cleanup_mock_env

# Test 15: Function isolation (source without arguments)
run_test "Script can be sourced" "bash -c 'source \"$SIMPLE_SOURCE\" gcc >/dev/null 2>&1 && [[ -n \"\${source_urls[0]}\" ]]'"

# Set up mock env for sourcing test
setup_mock_env

# Test 16: Global variables are set correctly
run_test "Global source_urls array" "bash -c 'export PATH=\"$SCRIPT_DIR:\$PATH\"; source \"$SIMPLE_SOURCE\" gcc >/dev/null 2>&1 && [[ -n \"\${source_urls[0]}\" ]]'"

cleanup_mock_env

# Test 17: Print function works correctly
run_test_with_output "Print function INFO level" "bash -c 'source \"$SIMPLE_SOURCE\" >/dev/null 2>&1; verbose=1; print_msg \"INFO\" \"test message\" 2>&1'" '\[INFO\] test message'

# Test 18: Print function DEBUG level suppressed at INFO
run_test_with_output "Print function DEBUG suppressed" "bash -c 'source \"$SIMPLE_SOURCE\" >/dev/null 2>&1; verbose=1; print_msg \"DEBUG\" \"debug message\" 2>&1'" "^$"

printf '\n=== SUMMARY ===\n'
printf 'Total tests: %d\n' "$total_tests"
printf 'Passed: %d\n' "$passed_tests"
printf 'Failed: %d\n' "$((total_tests - passed_tests))"

if [[ $passed_tests -eq $total_tests ]]; then
	printf '🎉 ALL TESTS PASSED!\n'
	exit 0
else
	printf '❌ Some tests failed\n'
	exit 1
fi