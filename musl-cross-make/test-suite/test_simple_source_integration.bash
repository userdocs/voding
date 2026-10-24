#!/bin/bash

# Integration test suite for simple_source script (network-dependent)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
simple_source="$script_dir/../simple_source"

printf '%s\n' "=== SIMPLE_SOURCE INTEGRATION TESTS ==="
printf '%s\n' "Testing script: $simple_source (requires network)"

total_tests=0
passed_tests=0

run_test_with_output() {
	local test_name="$1"
	local expected_pattern="$2"
	local expected_exit="$3"
	shift 3

	((++total_tests))
	printf '\n[%d] Testing: %s\n' "$total_tests" "$test_name"

	local output
	local actual_exit
	output=$(timeout 30 "$@" 2>&1)
	actual_exit=$?

	local pass=0
	if [[ $actual_exit -eq $expected_exit ]]; then
		if [[ -n $expected_pattern && $output =~ $expected_pattern ]] || [[ -z $expected_pattern ]]; then
			pass=1
		fi
	fi

	if [[ $pass -eq 1 ]]; then
		printf '  ✓ PASS\n'
		((++passed_tests))
	else
		printf '  ✗ FAIL (expected exit %d, got %d)\n' "$expected_exit" "$actual_exit"
		printf '  Output: %s\n' "$output"
		[[ -n $expected_pattern ]] && printf '  Expected pattern: %s\n' "$expected_pattern"
	fi
}

# Test 1: Real GCC version discovery
run_test_with_output "Real GCC version discovery" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 0 \
	"$simple_source" gcc

# Test 2: Real Binutils version discovery
run_test_with_output "Real Binutils version discovery" "^[0-9]+\.[0-9]+(\.[0-9]+)?$" 0 \
	"$simple_source" binutils

# Test 3: Real mirror discovery (matches any configured HTTP/HTTPS GNU mirror)
run_test_with_output "Real mirror discovery" "^https?://.*/gnu$" 0 \
	"$simple_source"

# Test 4: Real preferred mirror (GNU FTP)
run_test_with_output "Real preferred mirror" "^https://ftp\.gnu\.org/gnu$" 0 \
	"$simple_source" "https://ftp.gnu.org/gnu"

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
