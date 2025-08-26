#\!/bin/bash

# Simple comprehensive test runner
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_VERIFY="$SCRIPT_DIR/../patch_verify"

echo "=== PATCH_VERIFY TEST SUITE ==="
echo "Testing script: $PATCH_VERIFY"

total_tests=0
passed_tests=0

run_test() {
    local test_name="$1"
    local test_cmd="$2" 
    local expected_exit="$3"
    
    ((total_tests++))
    echo ""
    echo "[$total_tests] Testing: $test_name"
    
    eval "$test_cmd" >/dev/null 2>&1
    local actual_exit=$?
    
    if [[ $actual_exit -eq ${expected_exit:-0} ]]; then
        echo "  ✓ PASS"
        ((passed_tests++))
    else
        echo "  ✗ FAIL (expected exit $expected_exit, got $actual_exit)"
    fi
}

# Test 1: Help output
run_test "Help output" "\"$PATCH_VERIFY\" --help" 0

# Test 2: Usage display  
run_test "Usage display" "\"$PATCH_VERIFY\"" 0

# Test 3: Missing directory
run_test "Missing patch directory" "\"$PATCH_VERIFY\" nonexistent-patches" 1

# Test 4: Empty directory
mkdir -p empty-patches
run_test "Empty patch directory" "\"$PATCH_VERIFY\" empty-patches" 1
rmdir empty-patches

# Test 5: Dry run with patches
mkdir -p test-repo
cp source-files/* test-repo/ 2>/dev/null || true
run_test "Dry run mode" "\"$PATCH_VERIFY\" -r test-repo patches" 0
rm -rf test-repo

# Test 6: Verbose mode
mkdir -p test-repo2
cp source-files/* test-repo2/ 2>/dev/null || true
run_test "Verbose mode" "\"$PATCH_VERIFY\" -v -r test-repo2 patches" 0  
rm -rf test-repo2

# Test 7: Save failed patches
mkdir -p test-repo3
cp source-files/* test-repo3/ 2>/dev/null || true
run_test "Save failed patches" "\"$PATCH_VERIFY\" -s test-failed.txt -r test-repo3 patches" 0
[[ -f test-failed.txt ]] && echo "  ✓ Output file created" || echo "  - No output file (no failures)"
rm -f test-failed.txt
rm -rf test-repo3

echo ""
echo "=== SUMMARY ==="
echo "Total tests: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $((total_tests - passed_tests))"

if [[ $passed_tests -eq $total_tests ]]; then
    echo "🎉 ALL TESTS PASSED\!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi
