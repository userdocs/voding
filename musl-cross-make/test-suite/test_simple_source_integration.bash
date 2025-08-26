#!/bin/bash

# Integration test suite for simple_source script (network-dependent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMPLE_SOURCE="$SCRIPT_DIR/../simple_source"

printf '%s\n' "=== SIMPLE_SOURCE INTEGRATION TESTS ==="
printf '%s\n' "Testing script: $SIMPLE_SOURCE (requires network)"

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
	output=$(timeout 30 bash -c "$test_cmd" 2>&1)
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
	output=$(timeout 30 bash -c "$test_cmd" 2>&1)
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

# Test 1: Real GCC version discovery
run_test_with_output "Real GCC version discovery" "\"$SIMPLE_SOURCE\" gcc" "[0-9]+\.[0-9]+(\.[0-9]+)?"

# Test 2: Real Binutils version discovery
run_test_with_output "Real Binutils version discovery" "\"$SIMPLE_SOURCE\" binutils" "[0-9]+\.[0-9]+(\.[0-9]+)?"

# Test 3: Real mirror discovery
run_test_with_output "Real mirror discovery" "\"$SIMPLE_SOURCE\"" "https://.*\.gnu\.org/gnu"

# Test 4: Real preferred mirror (GNU FTP)
run_test_with_output "Real preferred mirror" "\"$SIMPLE_SOURCE\" https://ftp.gnu.org/gnu" "https://ftp\.gnu\.org/gnu"

printf '\n=== SUMMARY ===\n'
printf 'Total tests: %d\n' "$total_tests"
printf 'Passed: %d\n' "$passed_tests"
printf 'Failed: %d\n' "$((total_tests - passed_tests))"

if [[ $passed_tests -eq $total_tests ]]; then
	printf '🎉 ALL INTEGRATION TESTS PASSED!\n'
	exit 0
else
	printf '❌ Some integration tests failed\n'
	exit 1
fi
