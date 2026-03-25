#!/bin/bash

# Test suite for docker_here.sh script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_HERE="$SCRIPT_DIR/docker_here.sh"

printf '%s\n' "=== DOCKER_HERE TEST SUITE ==="
printf '%s\n' "Testing script: $DOCKER_HERE"

total_tests=0
passed_tests=0

run_test() {
	local test_name="$1"
	local test_cmd="$2"
	local expected_exit="${3:-0}"
	local expected_output="$4"

	((total_tests++))
	printf '\n[%d] Testing: %s\n' "$total_tests" "$test_name"

	local output
	local actual_exit
	output=$(eval "$test_cmd" 2>&1)
	actual_exit=$?

	local pass=true
	if [[ $actual_exit -ne $expected_exit ]]; then
		pass=false
		printf '  ✗ FAIL (expected exit %d, got %d)\n' "$expected_exit" "$actual_exit"
	fi

	if [[ -n $expected_output ]] && ! echo "$output" | grep -q "$expected_output"; then
		pass=false
		printf '  ✗ FAIL (did not find expected output: %s)\n' "$expected_output"
	fi

	if $pass; then
		printf '  ✓ PASS\n'
		((passed_tests++))
	else
		printf '  Output: %s\n' "$output"
	fi
}

setup_mock_env() {
	export PATH="$SCRIPT_DIR:$PATH"
	cat > "$SCRIPT_DIR/docker" << 'EOF'
#!/bin/bash
if [[ "$1" == "ps" ]]; then exit 0; fi
if [[ "$1" == "exec" || "$1" == "run" || "$1" == "start" ]]; then exit 0; fi
exit 0
EOF
	chmod +x "$SCRIPT_DIR/docker"
}

setup_mock_env

run_test "Help output rendering" "bash \"$DOCKER_HERE\" -h" 0
run_test "Invalid argument option rejection" "bash \"$DOCKER_HERE\" -Z" 1
run_test "Missing parameter (Platform) handler" "bash \"$DOCKER_HERE\" -p" 1
run_test "Conflicting options restriction check" "bash \"$DOCKER_HERE\" -s -l" 1
run_test "Script overall syntax verifier" "bash -n \"$DOCKER_HERE\"" 0
run_test "Mock container spawn execution (Alpine Persistent)" "bash \"$DOCKER_HERE\" -a -q" 0
run_test "Mock container spawn execution (Ubuntu Ephemeral Sudo)" "bash \"$DOCKER_HERE\" -u -s -r -q" 0
run_test "Mock container spawn execution with custom User (Valid)" "bash \"$DOCKER_HERE\" -d -l -r -U customuser -q" 0
run_test "Warns if custom user is passed without user mode" "bash \"$DOCKER_HERE\" -U customuser -q" 0 "WARNING: Custom user"
run_test "Mock container spawn execution with additional packages" "bash \"$DOCKER_HERE\" -a -P \"curl wget\" -r -q" 0

printf '\n=== SUMMARY ===\n'
printf 'Total tests: %d\n' "$total_tests"
printf 'Passed: %d\n' "$passed_tests"
printf 'Failed: %d\n' "$((total_tests - passed_tests))"

rm -f "$SCRIPT_DIR/docker"

[[ $passed_tests -eq $total_tests ]] && {
	printf '🎉 ALL TESTS PASSED!\n'
	exit 0
} || {
	printf '❌ Some tests failed\n'
	exit 1
}
