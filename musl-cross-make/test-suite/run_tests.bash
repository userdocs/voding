#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch_verify="$script_dir/../patch_verify"

# Colors
red='\e[31m'
green='\e[32m'
cyan='\e[36m'
end='\e[0m'
bold='\e[1m'

total_tests=0
passed_tests=0
failed_tests=0

# Isolated tmp dir; cleaned up on exit regardless of how the script ends
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ── Assertion helpers ─────────────────────────────────────────────────────────

_pass() {
	printf '  %b✓ PASS%b\n' "$green" "$end"
	((passed_tests++))
}

_fail() {
	printf '  %bFAIL: %s%b\n' "$red" "$1" "$end"
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
	out=$("$@" 2>&1)
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
	out=$("$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
	if printf '%s' "$out" | grep -q "$pattern"; then
		_pass
	else
		_fail "output did not contain: $pattern"
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
	out=$("$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
	if printf '%s' "$out" | grep -q "$pattern"; then
		_fail "output unexpectedly contained: $pattern"
	else
		_pass
	fi
}

# assert_file_contains <name> <file> <pattern>
assert_file_contains() {
	local name="$1"
	local file="$2"
	local pattern="$3"
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	if [[ -f $file ]] && grep -q "$pattern" "$file"; then
		_pass
	else
		_fail "file '$file' does not contain: $pattern"
	fi
}

# assert_file_absent <name> <file>
assert_file_absent() {
	local name="$1"
	local file="$2"
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	if [[ ! -f $file ]]; then
		_pass
	else
		_fail "file '$file' should not exist"
	fi
}

# assert_file_exists <name> <file>
assert_file_exists() {
	local name="$1"
	local file="$2"
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	if [[ -f $file ]]; then
		_pass
	else
		_fail "file '$file' should exist but does not"
	fi
}

# assert_file_modified <name> <file> <original_content>
assert_file_modified() {
	local name="$1"
	local file="$2"
	local original="$3"
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	local current
	current="$(cat "$file" 2> /dev/null)"
	if [[ $current != "$original" ]]; then
		_pass
	else
		_fail "file '$file' was not modified"
	fi
}

# assert_file_unchanged <name> <file> <original_content>
assert_file_unchanged() {
	local name="$1"
	local file="$2"
	local original="$3"
	((total_tests++))
	printf '\n[%d] %s\n' "$total_tests" "$name"
	local current
	current="$(cat "$file" 2> /dev/null)"
	if [[ $current == "$original" ]]; then
		_pass
	else
		_fail "file '$file' should be unchanged but was modified"
	fi
}

# ── Directory factory helpers ─────────────────────────────────────────────────
# Each prints the path it created (capture with $(...))

make_target_dir() {
	local dir="$tmp_dir/$1"
	mkdir -p "$dir"
	cp "$script_dir/source-files/"* "$dir/" 2> /dev/null
	printf '%s' "$dir"
}

make_valid_patches_dir() {
	local dir="$tmp_dir/$1"
	mkdir -p "$dir"
	cp "$script_dir/patches/valid.patch" "$dir/"
	printf '%s' "$dir"
}

make_invalid_patches_dir() {
	local dir="$tmp_dir/$1"
	mkdir -p "$dir"
	cp "$script_dir/patches/invalid.patch" "$dir/"
	printf '%s' "$dir"
}

make_mixed_patches_dir() {
	local dir="$tmp_dir/$1"
	mkdir -p "$dir"
	cp "$script_dir/patches/"*.patch "$dir/"
	printf '%s' "$dir"
}

make_git_repo() {
	local dir="$tmp_dir/$1"
	mkdir -p "$dir"
	cp "$script_dir/source-files/"* "$dir/" 2> /dev/null
	git -C "$dir" init -q
	git -C "$dir" config user.email "test@example.com"
	git -C "$dir" config user.name "Test"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "initial"
	printf '%s' "$dir"
}

section() {
	printf '\n%b%b── %s %b\n' "$bold" "$cyan" "$1" "$end"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

printf '%b%bPATCH_VERIFY TEST SUITE%b\n' "$bold" "$cyan" "$end"
printf 'Script: %s\n' "$patch_verify"

section "CLI / Argument Parsing"

run_test "No args shows usage, exits 0" 0 \
	"$patch_verify"

run_test "--help exits 0" 0 \
	"$patch_verify" --help

run_test "-h exits 0" 0 \
	"$patch_verify" -h

assert_output "--help output contains script basename" "patch_verify" \
	"$patch_verify" --help

run_test "Unknown option exits 1" 1 \
	"$patch_verify" --unknown-flag

run_test "--repo with no argument exits 1" 1 \
	"$patch_verify" --repo

run_test "--save-failed with no argument exits 1" 1 \
	"$patch_verify" --save-failed

run_test "Multiple positional patch dirs exits 1" 1 \
	"$patch_verify" dir1 dir2

section "Dry Run"

run_test "Missing patch dir exits 1" 1 \
	"$patch_verify" "$tmp_dir/nonexistent"

empty_dir="$tmp_dir/empty-patches"
mkdir -p "$empty_dir"
run_test "Empty patch dir exits 1" 1 \
	"$patch_verify" "$empty_dir"

target=$(make_target_dir "dr-valid")
patches=$(make_valid_patches_dir "dp-valid")
run_test "All valid patches exits 0" 0 \
	"$patch_verify" -r "$target" "$patches"

# Dry run must not modify files even when the patch is valid
target=$(make_target_dir "dr-nomod")
patches=$(make_valid_patches_dir "dp-nomod")
hello_before="$(cat "$target/hello.c")"
"$patch_verify" -r "$target" "$patches" > /dev/null 2>&1
assert_file_unchanged "Dry run does not modify target files" "$target/hello.c" "$hello_before"

target=$(make_target_dir "dr-invalid")
patches=$(make_invalid_patches_dir "dp-invalid")
run_test "All invalid patches exits 1" 1 \
	"$patch_verify" -r "$target" "$patches"

target=$(make_target_dir "dr-mixed")
patches=$(make_mixed_patches_dir "dp-mixed")
run_test "Mixed patches exits 1" 1 \
	"$patch_verify" -r "$target" "$patches"

# Explicit -d flag behaves same as default
target=$(make_target_dir "dr-explicit-d")
patches=$(make_valid_patches_dir "dp-explicit-d")
run_test "Explicit -d flag, valid patches exits 0" 0 \
	"$patch_verify" -d -r "$target" "$patches"

# .diff extension
target=$(make_target_dir "dr-diff")
diff_dir="$tmp_dir/diff-patches"
mkdir -p "$diff_dir"
cp "$script_dir/patches/valid.patch" "$diff_dir/valid.diff"
run_test ".diff extension recognised" 0 \
	"$patch_verify" -r "$target" "$diff_dir"

# Verbose output contains failure reason
target=$(make_target_dir "dr-verbose")
patches=$(make_invalid_patches_dir "dp-verbose")
assert_output "Verbose mode shows Reason on failure" "Reason" \
	"$patch_verify" -v -r "$target" "$patches"

# Non-verbose error shows only one line (no multi-line reason)
target=$(make_target_dir "dr-nonverbose")
patches=$(make_invalid_patches_dir "dp-nonverbose")
assert_output "Non-verbose shows failure indicator" "Failed" \
	"$patch_verify" -r "$target" "$patches"

section "Dry Run – Output Features"

# --save-failed writes failed patch name to file
target=$(make_target_dir "sf-fail")
patches=$(make_invalid_patches_dir "dp-sf-fail")
save_file="$tmp_dir/failed.txt"
"$patch_verify" -r "$target" "$patches" -s "$save_file" > /dev/null 2>&1
assert_file_contains "--save-failed writes failed patch name" \
	"$save_file" "invalid.patch"

# --save-failed is NOT written when there are no failures
target=$(make_target_dir "sf-pass")
patches=$(make_valid_patches_dir "dp-sf-pass")
save_file_pass="$tmp_dir/should-not-exist.txt"
"$patch_verify" -r "$target" "$patches" -s "$save_file_pass" > /dev/null 2>&1
assert_file_absent "--save-failed not written when no failures" "$save_file_pass"

# --save-failed must record basename only (not the full patch path)
target=$(make_target_dir "sf-basename")
patches=$(make_invalid_patches_dir "dp-sf-basename")
basename_file="$tmp_dir/basename-check.txt"
"$patch_verify" -r "$target" "$patches" -s "$basename_file" > /dev/null 2>&1
assert_file_contains "--save-failed records basename only" "$basename_file" "^invalid\.patch$"
assert_not_output "--save-failed does not embed full path in save file" "/" \
	cat "$basename_file"

# --save-failed works in apply mode, not only dry_run
target=$(make_target_dir "sf-apply")
patches=$(make_invalid_patches_dir "dp-sf-apply")
apply_save_file="$tmp_dir/apply-failed.txt"
"$patch_verify" -a -r "$target" "$patches" -s "$apply_save_file" > /dev/null 2>&1
assert_file_contains "--save-failed works in apply mode" "$apply_save_file" "invalid.patch"

# --save-failed records ALL failed patches when multiple exist
target=$(make_target_dir "sf-multi")
multi_invalid="$tmp_dir/multi-invalid"
mkdir -p "$multi_invalid"
cp "$script_dir/patches/invalid.patch" "$multi_invalid/first.patch"
cp "$script_dir/patches/invalid.patch" "$multi_invalid/second.patch"
multi_save="$tmp_dir/multi-failed.txt"
"$patch_verify" -r "$target" "$multi_invalid" -s "$multi_save" > /dev/null 2>&1
assert_file_contains "--save-failed records all failures (first)" "$multi_save" "first.patch"
assert_file_contains "--save-failed records all failures (second)" "$multi_save" "second.patch"

# --delete-failed removes failing patch, leaves passing patch
target=$(make_target_dir "del-target")
del_patches="$tmp_dir/del-patches"
mkdir -p "$del_patches"
cp "$script_dir/patches/invalid.patch" "$del_patches/"
cp "$script_dir/patches/valid.patch" "$del_patches/"
"$patch_verify" -r "$target" "$del_patches" -x > /dev/null 2>&1

assert_file_absent "--delete-failed removes invalid patch from dir" "$del_patches/invalid.patch"
assert_file_exists "--delete-failed preserves valid patch in dir" "$del_patches/valid.patch"

section "Apply Mode"

target=$(make_target_dir "ap-valid")
patches=$(make_valid_patches_dir "ap-dp-valid")
original_content="$(cat "$target/hello.c")"
run_test "Apply valid patch exits 0" 0 \
	"$patch_verify" -a -r "$target" "$patches"
assert_file_modified "Apply valid patch modifies target file" \
	"$target/hello.c" "$original_content"

target=$(make_target_dir "ap-invalid")
patches=$(make_invalid_patches_dir "ap-dp-invalid")
original_content="$(cat "$target/hello.c")"
run_test "Apply invalid patch exits 1" 1 \
	"$patch_verify" -a -r "$target" "$patches"
assert_file_unchanged "Apply invalid patch leaves target file unchanged" \
	"$target/hello.c" "$original_content"

# Applying the same patch twice should fail the second time
target=$(make_target_dir "ap-twice")
patches=$(make_valid_patches_dir "ap-dp-twice")
"$patch_verify" -a -r "$target" "$patches" > /dev/null 2>&1
run_test "Applying already-applied patch exits 1" 1 \
	"$patch_verify" -a -r "$target" "$patches"

# Verbose apply failure must show the 'Detailed error' diagnostic block
target=$(make_target_dir "ap-verbose-detail")
patches=$(make_invalid_patches_dir "dp-ap-verbose-detail")
assert_output "Verbose apply failure shows 'Detailed error'" "Detailed error" \
	"$patch_verify" -a -v -r "$target" "$patches"

# Non-verbose apply failure must NOT show the 'Detailed error' block
target=$(make_target_dir "ap-noverbose-detail")
patches=$(make_invalid_patches_dir "dp-ap-noverbose-detail")
assert_not_output "Non-verbose apply failure omits 'Detailed error'" "Detailed error" \
	"$patch_verify" -a -r "$target" "$patches"

section "Apply Mode – Git Repo"

if command -v git > /dev/null 2>&1; then
	git_repo=$(make_git_repo "git-valid")
	patches=$(make_valid_patches_dir "git-dp-valid")
	run_test "git: apply valid patch exits 0" 0 \
		"$patch_verify" -a -r "$git_repo" "$patches"

	git_repo=$(make_git_repo "git-invalid")
	patches=$(make_invalid_patches_dir "git-dp-invalid")
	run_test "git: apply invalid patch exits 1" 1 \
		"$patch_verify" -a -r "$git_repo" "$patches"

	git_repo=$(make_git_repo "git-dryrun")
	patches=$(make_valid_patches_dir "git-dp-dryrun")
	run_test "git: dry run valid patch exits 0" 0 \
		"$patch_verify" -r "$git_repo" "$patches"

	git_repo=$(make_git_repo "git-dryrun-invalid")
	patches=$(make_invalid_patches_dir "git-dp-dryrun-invalid")
	run_test "git: dry run invalid patch exits 1" 1 \
		"$patch_verify" -r "$git_repo" "$patches"
else
	printf '\n  (skipping git tests: git not available)\n'
fi

section "Invariants"

# apply_patches must restore cwd to where it was before the call
cwd_target=$(make_target_dir "cwd-check")
cwd_patches=$(make_valid_patches_dir "cwd-dp-check")
run_test "apply_patches restores cwd after execution" 0 \
	bash -c "source \"$patch_verify\" && before=\"\$(pwd)\" && apply_patches \"$cwd_patches\" true false false \"$cwd_target\" '' false > /dev/null 2>&1 && [[ \"\$(pwd)\" == \"\$before\" ]]"

# apply_patches must restore cwd even when the patch fails
cwd_target2=$(make_target_dir "cwd-fail")
cwd_patches2=$(make_invalid_patches_dir "cwd-dp-fail")
run_test "apply_patches restores cwd after failure" 0 \
	bash -c "source \"$patch_verify\" && before=\"\$(pwd)\" && apply_patches \"$cwd_patches2\" true false false \"$cwd_target2\" '' false > /dev/null 2>&1; [[ \"\$(pwd)\" == \"\$before\" ]]"

section "Source Guard"

# After sourcing, apply_patches function must be defined (proves exit was not called)
run_test "Sourcing defines apply_patches function" 0 \
	bash -c "source \"$patch_verify\" && declare -f apply_patches > /dev/null"

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
