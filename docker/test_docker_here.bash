#!/bin/bash
set -eo pipefail

# Test suite for the docker_here.sh script

# --- Test Setup ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_HERE_SCRIPT="$SCRIPT_DIR/docker_here.sh"
MOCK_DIR="$SCRIPT_DIR/mock"
MOCK_DOCKER_PATH="$MOCK_DIR/docker"
DOCKER_CALL_LOG="$MOCK_DIR/docker_calls.log"

source "$DOCKER_HERE_SCRIPT"

total_tests=0
passed_tests=0

# --- Mocking Environment ---
setup_mock_env() {
	mkdir -p "$MOCK_DIR"
	# Create a mock 'docker' command
	cat > "$MOCK_DOCKER_PATH" << 'EOF'
#!/bin/bash
# Mock Docker command for testing
echo "docker $@" >> "$DOCKER_CALL_LOG"

# Simulate specific command outputs needed by the script
case "$1" in
    ps)
        # To test container reuse, make 'ps' return a container name on the second run
        if [[ -f "/tmp/dh_test_container_exists" ]]; then
            echo "alpine_mock_project"
        fi
        ;;
    exec)
        # Simulate successful command execution inside the container
        if [[ "$*" == *"command -v bash"* || "$*" == *"test -d"* || "$*" == *"id"* ]]; then
            return 0
        fi
        ;;
    start|stop|rm|rmi|run)
        # Simulate success for lifecycle commands
        return 0
        ;;
esac
EOF
	chmod +x "$MOCK_DOCKER_PATH"
	# Prepend mock directory to PATH
	export PATH="$MOCK_DIR:$PATH"
	# Reset log and state files
	> "$DOCKER_CALL_LOG"
	rm -f /tmp/dh_test_container_exists
}

cleanup_mock_env() {
	rm -rf "$MOCK_DIR"
	rm -f /tmp/dh_test_container_exists
	# Restore original PATH
	export PATH="${PATH#*:$MOCK_DIR}"
}

# --- Test Runner ---
run_test() {
	local test_name="$1"
	shift
	local test_cmd="$1"
	shift
	local expected_pattern="$1"
	shift
	local expected_exit="${1:-0}"

	((total_tests++))
	printf '\n[%d] Testing: %s\n' "$total_tests" "$test_name"

	# Setup mock environment for each test
	setup_mock_env

	local output
	local actual_exit
	# shellcheck disable=SC2091
	output=$(eval "$test_cmd" 2>&1) || actual_exit=$?
	actual_exit=${?:-0}

	local test_passed=false
	if [[ $actual_exit -eq $expected_exit ]]; then
		if [[ -z $expected_pattern ]] || grep -qE "$expected_pattern" "$DOCKER_CALL_LOG"; then
			test_passed=true
		fi
	fi

	if $test_passed; then
		printf '  ✓ PASS\n'
		((passed_tests++))
	else
		printf '  ✗ FAIL\n'
		printf '    - Expected Exit: %d, Got: %d\n' "$expected_exit" "$actual_exit"
		if [[ -n $expected_pattern ]]; then
			printf '    - Expected Pattern: %s\n' "$expected_pattern"
			printf '    - Docker Calls Log:\n'
			sed 's/^/        /g' "$DOCKER_CALL_LOG"
		fi
		printf '    - Script Output:\n'
		printf '%s\n' "$output" | sed 's/^/        /g'
	fi

	# Clean up mock environment
	cleanup_mock_env
}

# --- Test Cases ---

printf '%s\n' "=== DOCKER_HERE TEST SUITE ==="

# Basic functionality
run_test "Default behavior (alpine)" \
	"_dh -q" \
	"run .* alpine:edge"

run_test "Ubuntu selection" \
	"_dh -q -u" \
	"run .* ubuntu:latest"

run_test "Debian selection" \
	"_dh -q -d" \
	"run .* debian:latest"

run_test "Custom image version" \
	"_dh -q -i alpine:3.18" \
	"run .* alpine:3.18"

# Modes and options
run_test "Ephemeral mode (-r)" \
	"_dh -q -r" \
	"run .* --rm .*"

run_test "Force new container (-n)" \
	"_dh -q -n" \
	"rm -f alpine_.*"

run_test "Delete all (-D)" \
	"_dh -q -D" \
	"rmi -f alpine:edge"

# User and permissions
run_test "Sudo user mode (-s)" \
	"_dh -q -s" \
	"exec .* sudo"

run_test "Limited user mode (-l)" \
	"_dh -q -l" \
	"exec .* useradd"

run_test "Custom username (-U)" \
	"_dh -q -s -U testuser" \
	"exec .* testuser "

run_test "Sudo and Limited mode conflict" \
	"_dh -q -s -l" \
	"" \
	"1"

# Volume mounting
run_test "Custom volume path (-v)" \
	"_dh -q -v /tmp/testvol" \
	"run .* -v /tmp/testvol:/root"

# Package installation
run_test "Additional packages (-P)" \
	'_dh -q -s -P "curl wget"' \
	"exec .* curl wget"

# Security validation tests
run_test "Invalid username" \
	"_dh -q -U 'invalid;user'" \
	"" \
	"1"

run_test "Invalid package name" \
	"_dh -q -P 'bad-pkg; rm -rf /'" \
	"" \
	"1"

# Test container reuse logic
printf '\n[%d] Testing: %s\n' "$((++total_tests))" "Container reuse"
setup_mock_env
touch /tmp/dh_test_container_exists # Make the mock 'docker ps' find a container
output=$(cd "$MOCK_DIR" && _dh -q 2>&1)
if grep -q "attach" "$DOCKER_CALL_LOG"; then
	printf '  ✓ PASS\n'
	((passed_tests++))
else
	printf '  ✗ FAIL\n'
	printf '    - Expected "attach" call, but not found.\n'
	printf '    - Docker Calls Log:\n'
	sed 's/^/        /g' "$DOCKER_CALL_LOG"
fi
cleanup_mock_env

# --- Summary ---
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
