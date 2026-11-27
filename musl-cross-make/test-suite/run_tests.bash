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
	if printf '%s' "$out" | grep -q -- "$pattern"; then
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
	if printf '%s' "$out" | grep -q -- "$pattern"; then
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
	if [[ -f $file ]] && grep -q -- "$pattern" "$file"; then
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

patches_for_bad_repo=$(make_valid_patches_dir "dp-bad-repo")
run_test "Missing --repo target dir exits 1" 1 \
	"$patch_verify" -r "$tmp_dir/nonexistent-repo" "$patches_for_bad_repo"

empty_dir="$tmp_dir/empty-patches"
mkdir -p "$empty_dir"
run_test "Empty patch dir exits 1" 1 \
	"$patch_verify" "$empty_dir"

target=$(make_target_dir "dr-valid")
patches=$(make_valid_patches_dir "dp-valid")
run_test "All valid patches exits 0" 0 \
	"$patch_verify" -r "$target" "$patches"

# Default 'patches' directory used when flag is given without positional arg
def_work=$(make_target_dir "dr-default-dir")
mkdir -p "$def_work/patches"
cp "$script_dir/patches/valid.patch" "$def_work/patches/"
run_test "Default 'patches' directory used when omitted" 0 \
	bash -c "cd \"$def_work\" && \"$patch_verify\" -d"

# Relative paths for -r, patch_dir, and -s
make_target_dir "rel-target" > /dev/null
make_invalid_patches_dir "rel-patches" > /dev/null
run_test "Relative paths resolved for -r, patch_dir, and -s" 1 \
	bash -c "cd \"$tmp_dir\" && \"$patch_verify\" -r rel-target rel-patches -s rel-failed.txt"
assert_file_contains "Relative -s file created in caller dir" \
	"$tmp_dir/rel-failed.txt" "invalid.patch"

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

# Verbose dry-run preserves multi-line reason; non-verbose truncates to 1 line
target=$(make_target_dir "dr-verbose")
patches=$(make_invalid_patches_dir "dp-verbose")
assert_output "Verbose dry-run shows multi-line patch error details" "Perhaps you used the wrong -p" \
	"$patch_verify" -v -r "$target" "$patches"

target=$(make_target_dir "dr-nonverbose")
patches=$(make_invalid_patches_dir "dp-nonverbose")
assert_not_output "Non-verbose dry-run truncates multi-line error to first line" "Perhaps you used the wrong -p" \
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

# Multi-hunk patch where hunk 1 passes and hunk 2 fails must not partially modify target
target=$(make_target_dir "ap-partial")
partial_patches="$tmp_dir/dp-ap-partial"
mkdir -p "$partial_patches"
cat > "$partial_patches/partial.patch" << 'EOF'
--- a/config.txt
+++ b/config.txt
@@ -1,2 +1,2 @@
-# Configuration file
+# Modified header
 version=1.0
@@ -3,2 +3,2 @@
-nonexistent_line=true
+nonexistent_line=false
 feature_x=enabled
EOF
config_before="$(cat "$target/config.txt")"
run_test "Multi-hunk failing patch exits 1 in apply mode" 1 \
	"$patch_verify" -a -f -r "$target" "$partial_patches"
assert_file_unchanged "Multi-hunk failing patch does not partially mutate file" \
	"$target/config.txt" "$config_before"

# Mixed .diff and .patch ordering: 01.diff must apply before 02.patch
target=$(make_target_dir "ap-order")
order_patches="$tmp_dir/dp-ap-order"
mkdir -p "$order_patches"
cp "$script_dir/patches/valid.patch" "$order_patches/01-first.diff"
cat > "$order_patches/02-second.patch" << 'EOF'
--- a/hello.c
+++ b/hello.c
@@ -3,6 +3,7 @@
 int main() {
 	printf("Hello World\n");
 	printf("Patched successfully!\n");
+	printf("Second patch applied in order!\n");
 	return 0;
 }
EOF
run_test "Mixed .diff and .patch applied in lexicographical order" 0 \
	"$patch_verify" -a -r "$target" "$order_patches"
assert_file_contains "Dependent second patch applied after first .diff" \
	"$target/hello.c" "Second patch applied in order!"

# --force (-f) recovers from whitespace differences in non-git target
ws_apply_target=$(make_target_dir "ap-ws")
ws_patches="$tmp_dir/dp-ap-ws"
mkdir -p "$ws_patches"
cat > "$ws_patches/ws.patch" << 'EOF'
--- a/hello.c
+++ b/hello.c
@@ -2,5 +2,6 @@
 
 int main() {
-    printf("Hello World\n");
+    printf("Hello World\n");
+    printf("Whitespace force applied!\n");
     return 0;
 }
EOF
run_test "Whitespace mismatch fails without -f in non-git dir" 1 \
	"$patch_verify" -a -r "$ws_apply_target" "$ws_patches"
run_test "Whitespace mismatch succeeds with -a -f in non-git dir" 0 \
	"$patch_verify" -a -f -r "$ws_apply_target" "$ws_patches"

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

	# git: --force (-f) recovers from whitespace mismatch
	git_ws_repo=$(make_git_repo "git-ws")
	run_test "git: whitespace mismatch fails without -f" 1 \
		"$patch_verify" -a -r "$git_ws_repo" "$ws_patches"
	run_test "git: whitespace mismatch succeeds with -a -f" 0 \
		"$patch_verify" -a -f -r "$git_ws_repo" "$ws_patches"

	# git: 3-way merge succeeds when context has changed but merge has no conflicts
	git_3way_repo=$(make_git_repo "git-3way")
	threeway_patches="$tmp_dir/dp-git-3way"
	mkdir -p "$threeway_patches"
	git -C "$git_3way_repo" checkout -q -b patch-branch
	sed -i 's/feature_x=enabled/feature_x=disabled/' "$git_3way_repo/config.txt"
	git -C "$git_3way_repo" commit -q -a -m "patch change"
	git -C "$git_3way_repo" show --format= > "$threeway_patches/3way.patch"
	git -C "$git_3way_repo" checkout -q -
	sed -i 's/version=1.0/version=2.0/' "$git_3way_repo/config.txt"
	git -C "$git_3way_repo" commit -q -a -m "context change"
	assert_output "git: 3-way merge applies diverged patch cleanly" "Applied with 3-way merge" \
		"$patch_verify" -a -r "$git_3way_repo" "$threeway_patches"
	assert_file_contains "git: 3-way merge preserves local context change" \
		"$git_3way_repo/config.txt" "version=2.0"
	assert_file_contains "git: 3-way merge applies incoming patch change" \
		"$git_3way_repo/config.txt" "feature_x=disabled"

	# git: conflicting 3-way merge fails without leaving conflict markers
	git_conflict_repo=$(make_git_repo "git-conflict")
	conflict_patches="$tmp_dir/dp-git-conflict"
	mkdir -p "$conflict_patches"
	git -C "$git_conflict_repo" checkout -q -b conflict-branch
	sed -i 's/version=1.0/version=2.0/' "$git_conflict_repo/config.txt"
	git -C "$git_conflict_repo" commit -q -a -m "version 2.0"
	git -C "$git_conflict_repo" show --format= > "$conflict_patches/conflict.patch"
	git -C "$git_conflict_repo" checkout -q -
	sed -i 's/version=1.0/version=3.0/' "$git_conflict_repo/config.txt"
	git -C "$git_conflict_repo" commit -q -a -m "version 3.0"
	conflict_before="$(cat "$git_conflict_repo/config.txt")"
	run_test "git: conflicting 3-way merge exits 1" 1 \
		"$patch_verify" -a -f -r "$git_conflict_repo" "$conflict_patches"
	assert_file_unchanged "git: conflicting 3-way merge leaves working tree clean" \
		"$git_conflict_repo/config.txt" "$conflict_before"

	# git: worktree (.git as a file) is detected as a git repository
	wt_base=$(make_git_repo "git-wt-base")
	wt_dir="$tmp_dir/git-wt-linked"
	git -C "$wt_base" worktree add -q -b wt-branch "$wt_dir"
	wt_patches=$(make_valid_patches_dir "git-dp-wt")
	assert_output "git: worktree (.git file) detected as git repository" "Target git repository" \
		"$patch_verify" -r "$wt_dir" "$wt_patches"
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

# Sourcing multiple times or alongside caller color variables must produce no readonly errors
assert_not_output "Re-sourcing patch_verify produces no readonly errors" "readonly" \
	bash -c "color_red='x'; source \"$patch_verify\" && source \"$patch_verify\" && color_red='y'"

# Calling apply_patches when sourced must not leak internal helper state into global scope
run_test "apply_patches does not leak internal security state globals" 0 \
	bash -c "source \"$patch_verify\" && apply_patches \"$cwd_patches\" true false false \"$cwd_target\" '' false > /dev/null 2>&1 && [[ -z \${patch_security_error+x} && -z \${checked_rel_path+x} ]]"

section "Hardening, Security & Regression Tests"

# Static syntax check
run_test "bash -n syntax check on patch_verify" 0 \
	bash -n "$patch_verify"

# Shellcheck check (if installed)
if command -v shellcheck > /dev/null 2>&1; then
	run_test "shellcheck clean on patch_verify and run_tests.bash" 0 \
		shellcheck -s bash "$patch_verify" "${BASH_SOURCE[0]}"
fi

# Invalid boolean argument to apply_patches fails cleanly
run_test "apply_patches rejects invalid boolean parameter" 1 \
	bash -c "source \"$patch_verify\" && apply_patches \"$cwd_patches\" invalid_bool false false \"$cwd_target\" '' false"

# Path traversal ('..') in patch headers is blocked in both dry-run and apply modes
trav_target=$(make_target_dir "trav-target")
trav_patches="$tmp_dir/dp-trav"
mkdir -p "$trav_patches"
printf 'safe' > "$tmp_dir/outside_victim.txt"
cat > "$trav_patches/traversal.patch" << 'EOF'
--- a/../outside_victim.txt
+++ b/../outside_victim.txt
@@ -1 +1 @@
-safe
+pwned
EOF
run_test "Path traversal patch blocked in dry-run mode" 1 \
	"$patch_verify" -r "$trav_target" "$trav_patches"
run_test "Path traversal patch blocked in apply mode" 1 \
	"$patch_verify" -a -r "$trav_target" "$trav_patches"
assert_file_unchanged "Outside file untouched by traversal patch" \
	"$tmp_dir/outside_victim.txt" "safe"

# Missing 'patch' command must exit 1 and MUST NOT delete patches when -x is passed
nopatch_target=$(make_target_dir "nopatch-target")
nopatch_dir=$(make_valid_patches_dir "dp-nopatch")
empty_bin="$tmp_dir/empty-bin"
mkdir -p "$empty_bin"
ln -sf "$(command -v bash)" "$empty_bin/bash"
ln -sf "$(command -v grep)" "$empty_bin/grep"
run_test "Missing patch binary exits 1 cleanly" 1 \
	env PATH="$empty_bin" "$empty_bin/bash" "$patch_verify" -x -r "$nopatch_target" "$nopatch_dir"
assert_file_exists "Missing patch binary with -x does NOT delete patches" \
	"$nopatch_dir/valid.patch"

# Dry-run with -f (--force) matches apply -f for whitespace-mismatch patches (non-git)
ws_dr_target=$(make_target_dir "dr-ws-force")
run_test "Dry-run with -f accepts whitespace-mismatch patch (non-git)" 0 \
	"$patch_verify" -d -f -r "$ws_dr_target" "$ws_patches"

# Applying with -f in non-git dir does not leave .orig backup files behind
assert_file_absent "Non-git -a -f leaves no .orig backup file behind" \
	"$ws_apply_target/hello.c.orig"

# Empty (0-byte) patch file is rejected in both non-git and git modes
empty_patch_target=$(make_target_dir "empty-file-target")
empty_patch_dir="$tmp_dir/dp-empty-file"
mkdir -p "$empty_patch_dir"
: > "$empty_patch_dir/zero.patch"
assert_output "Empty 0-byte patch rejected in non-git dry-run" "Patch file is empty" \
	"$patch_verify" -r "$empty_patch_target" "$empty_patch_dir"
run_test "Empty 0-byte patch exits 1 in non-git apply mode" 1 \
	"$patch_verify" -a -r "$empty_patch_target" "$empty_patch_dir"

# Legitimate hunk lines starting with '-- ' and containing '..' (e.g. Ada/SQL comments) are NOT false-flagged
ada_target="$tmp_dir/ada-target"
ada_patches="$tmp_dir/dp-ada"
mkdir -p "$ada_target" "$ada_patches"
printf -- '--  Check range 1 .. 10\nx = 1;\n' > "$ada_target/range.adb"
cat > "$ada_patches/ada_range.patch" << 'EOF'
--- a/range.adb
+++ b/range.adb
@@ -1,2 +1,2 @@
---  Check range 1 .. 10
+--  Check range 1 .. 20
 x = 1;
EOF
run_test "Hunk line starting with '-- ' and '..' allowed in dry-run" 0 \
	"$patch_verify" -r "$ada_target" "$ada_patches"
run_test "Hunk line starting with '-- ' and '..' applies cleanly" 0 \
	"$patch_verify" -a -r "$ada_target" "$ada_patches"
assert_file_contains "Ada range patch updated target file" \
	"$ada_target/range.adb" "1 \.\. 20"

# Legitimate filename containing '..' (not a parent directory segment) is allowed
dotfile_target="$tmp_dir/dotfile-target"
dotfile_patches="$tmp_dir/dp-dotfile"
mkdir -p "$dotfile_target" "$dotfile_patches"
printf 'v1\n' > "$dotfile_target/foo..bar.txt"
cat > "$dotfile_patches/dotfile.patch" << 'EOF'
--- a/foo..bar.txt
+++ b/foo..bar.txt
@@ -1 +1 @@
-v1
+v2
EOF
run_test "Filename containing '..' (foo..bar.txt) applies cleanly" 0 \
	"$patch_verify" -a -r "$dotfile_target" "$dotfile_patches"
assert_file_contains "foo..bar.txt updated to v2" \
	"$dotfile_target/foo..bar.txt" "^v2$"

# Security: C-quoted octal path traversal (\056\056) blocked
octal_patches="$tmp_dir/dp-octal-trav"
mkdir -p "$octal_patches"
cat > "$octal_patches/octal.patch" << 'EOF'
diff --git "a/\056\056/outside_victim.txt" "b/\056\056/outside_victim.txt"
--- "a/\056\056/outside_victim.txt"
+++ "b/\056\056/outside_victim.txt"
@@ -1 +1 @@
-safe
+pwned
EOF
assert_output "C-quoted octal '..' traversal blocked" "Security: patch contains parent directory traversal" \
	"$patch_verify" -r "$trav_target" "$octal_patches"

octal_ts_patches="$tmp_dir/dp-octal-ts-trav"
mkdir -p "$octal_ts_patches"
printf '%b' '--- "a/\\056\\056/outside_victim.txt"\t2026-01-01 00:00:00 +0000\n+++ "b/\\056\\056/outside_victim.txt"\t2026-01-01 00:00:00 +0000\n@@ -1 +1 @@\n-safe\n+pwned\n' \
	> "$octal_ts_patches/octal_ts.patch"
assert_output "C-quoted octal '..' header with tab timestamp blocked" "Security: patch contains parent directory traversal" \
	"$patch_verify" -r "$trav_target" "$octal_ts_patches"

# Security: spoofed git 'rename to' traversal blocked
rename_trav_patches="$tmp_dir/dp-rename-trav"
mkdir -p "$rename_trav_patches"
cat > "$rename_trav_patches/rename_trav.patch" << 'EOF'
diff --git a/hello.c b/hello2.c
similarity index 100%
rename from hello.c
rename to ../outside_victim.txt
EOF
assert_output "Git 'rename to' traversal blocked" "Security: patch contains parent directory traversal" \
	"$patch_verify" -r "$trav_target" "$rename_trav_patches"

# Security: absolute target path in patch header blocked
abs_patches="$tmp_dir/dp-abs-path"
mkdir -p "$abs_patches"
cat > "$abs_patches/abs.patch" << EOF
--- $tmp_dir/outside_victim.txt
+++ $tmp_dir/outside_victim.txt
@@ -1 +1 @@
-safe
+pwned
EOF
assert_output "Absolute path in patch header blocked" "Security: patch contains absolute target path" \
	"$patch_verify" -r "$trav_target" "$abs_patches"

# Security: escaping symlink patch (mode 120000) and symlink directory traversal blocked
sym_target_dir=$(make_target_dir "sym-target")
ln -s "$tmp_dir" "$sym_target_dir/escape_link"
sym_via_dir_patches="$tmp_dir/dp-sym-via-dir"
mkdir -p "$sym_via_dir_patches"
cat > "$sym_via_dir_patches/via_sym.patch" << 'EOF'
--- /dev/null
+++ b/escape_link/sym_created.txt
@@ -0,0 +1 @@
+pwned
EOF
assert_output "New file via pre-existing symlink dir blocked in dry-run" "Security: patch target traverses symbolic link" \
	"$patch_verify" -r "$sym_target_dir" "$sym_via_dir_patches"
run_test "New file via pre-existing symlink dir blocked in apply mode" 1 \
	"$patch_verify" -a -r "$sym_target_dir" "$sym_via_dir_patches"
assert_file_absent "Symlink traversal did not create file outside target" \
	"$tmp_dir/sym_created.txt"

sym_mode_patches="$tmp_dir/dp-sym-mode"
mkdir -p "$sym_mode_patches"
cat > "$sym_mode_patches/escape_sym.patch" << 'EOF'
diff --git a/bad_link b/bad_link
new file mode 120000
index 0000000..1234567
--- /dev/null
+++ b/bad_link
@@ -0,0 +1 @@
+../outside_victim.txt
\ No newline at end of file
EOF
assert_output "Escaping mode 120000 symlink blocked" "Security: patch creates escaping symbolic link" \
	"$patch_verify" -r "$trav_target" "$sym_mode_patches"

sym_twostep_patches="$tmp_dir/dp-sym-twostep"
mkdir -p "$sym_twostep_patches"
cat > "$sym_twostep_patches/twostep.patch" << 'EOF'
diff --git a/inner_link b/inner_link
new file mode 120000
index 0000000..1234567
--- /dev/null
+++ b/inner_link
@@ -0,0 +1 @@
+sub
\ No newline at end of file
diff --git a/inner_link/file.txt b/inner_link/file.txt
new file mode 100644
index 0000000..1234567
--- /dev/null
+++ b/inner_link/file.txt
@@ -0,0 +1 @@
+hello
EOF
assert_output "Intra-patch 2-step symlink write blocked" "Security: patch target traverses symbolic link" \
	"$patch_verify" -r "$trav_target" "$sym_twostep_patches"

# Security: --save-failed refuses to overwrite a symbolic link target
sym_save_victim="$tmp_dir/sym-save-victim.txt"
printf 'keep_safe' > "$sym_save_victim"
sym_save_link="$tmp_dir/sym-save-link.txt"
ln -s "$sym_save_victim" "$sym_save_link"
sym_save_patches=$(make_invalid_patches_dir "dp-sym-save")
assert_output "--save-failed warns and refuses symbolic link output" "Refusing to write failed patches to symbolic link" \
	"$patch_verify" -r "$trav_target" -s "$sym_save_link" "$sym_save_patches"
assert_file_unchanged "--save-failed symlink target left untouched" \
	"$sym_save_victim" "keep_safe"

# --delete-failed (-x) deletes read-only (0444) failing patch without hanging
ro_del_patches="$tmp_dir/dp-ro-del"
mkdir -p "$ro_del_patches"
cp "$script_dir/patches/invalid.patch" "$ro_del_patches/ro_invalid.patch"
chmod 0444 "$ro_del_patches/ro_invalid.patch"
run_test "--delete-failed removes mode 0444 failing patch cleanly" 1 \
	"$patch_verify" -d -x -r "$trav_target" "$ro_del_patches"
assert_file_absent "Read-only failing patch deleted by -x" \
	"$ro_del_patches/ro_invalid.patch"

# Non-git apply failure after dry-run passes reports actual apply error (not 'checking file')
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	ro_target=$(make_target_dir "ro-apply-target")
	ro_patches=$(make_valid_patches_dir "dp-ro-apply")
	chmod 0444 "$ro_target/hello.c"
	chmod 0555 "$ro_target"
	assert_not_output "Read-only target apply failure does not report dry-run 'checking file'" "checking file" \
		"$patch_verify" -a -r "$ro_target" "$ro_patches"
	chmod 0755 "$ro_target"
	chmod 0644 "$ro_target/hello.c"
fi

# Stale --save-failed file is removed when a subsequent run has 0 failures
stale_target=$(make_target_dir "sf-stale")
stale_patches=$(make_valid_patches_dir "dp-sf-stale")
stale_file="$tmp_dir/stale-failed.txt"
printf 'old_failure.patch\n' > "$stale_file"
run_test "Run with pre-existing save-failed file and all valid patches exits 0" 0 \
	"$patch_verify" -r "$stale_target" "$stale_patches" -s "$stale_file"
assert_file_absent "Stale --save-failed file removed when all patches succeed" \
	"$stale_file"

# Combined short flags (-avf), --repo=DIR, --save-failed=FILE, and -- end-of-options
combo_target=$(make_target_dir "combo-target")
combo_patches="$tmp_dir/dp-combo"
mkdir -p "$combo_patches"
cp "$ws_patches/ws.patch" "$combo_patches/"
run_test "Combined short flags -avf and --repo= apply whitespace patch" 0 \
	"$patch_verify" -avf --repo="$combo_target" -- "$combo_patches"

combo_fail_file="$tmp_dir/combo-failed.txt"
combo_inv_patches=$(make_invalid_patches_dir "dp-combo-inv")
run_test "--save-failed=FILE syntax records failed patch" 1 \
	"$patch_verify" --repo="$combo_target" --save-failed="$combo_fail_file" "$combo_inv_patches"
assert_file_contains "--save-failed=FILE wrote failed patch basename" \
	"$combo_fail_file" "^invalid\.patch$"

assert_output "Invalid flag inside 2-char short cluster reports offending flag" "Unknown option: -z (in -az)" \
	"$patch_verify" -az "$combo_patches"
run_test "Invalid flag inside combined short cluster exits 1" 1 \
	"$patch_verify" -az "$combo_patches"

if command -v git > /dev/null 2>&1; then
	# Git dry-run with -f accepts whitespace-mismatch patch and 3-way mergeable patch
	git_dr_ws=$(make_git_repo "git-dr-ws")
	run_test "git: dry-run with -f accepts whitespace-mismatch patch" 0 \
		"$patch_verify" -d -f -r "$git_dr_ws" "$ws_patches"

	git_dr_3way=$(make_git_repo "git-dr-3way")
	git -C "$git_dr_3way" checkout -q -b dr-patch-branch
	sed -i 's/feature_x=enabled/feature_x=disabled/' "$git_dr_3way/config.txt"
	git -C "$git_dr_3way" commit -q -a -m "patch change"
	dr_3way_patches="$tmp_dir/dp-git-dr-3way"
	mkdir -p "$dr_3way_patches"
	git -C "$git_dr_3way" show --format= > "$dr_3way_patches/3way.patch"
	git -C "$git_dr_3way" checkout -q -
	sed -i 's/version=1.0/version=2.0/' "$git_dr_3way/config.txt"
	git -C "$git_dr_3way" commit -q -a -m "context change"
	dr_3way_before="$(cat "$git_dr_3way/config.txt")"
	assert_output "git: dry-run recognizes 3-way mergeable patch" "OK (3-way merge)" \
		"$patch_verify" -d -r "$git_dr_3way" "$dr_3way_patches"
	assert_file_unchanged "git: dry-run 3-way check does not modify target file" \
		"$git_dr_3way/config.txt" "$dr_3way_before"

	# Git dry-run on conflicting 3-way patch must ALSO leave working tree untouched
	run_test "git: dry-run conflicting 3-way merge exits 1" 1 \
		"$patch_verify" -d -r "$git_conflict_repo" "$conflict_patches"
	assert_file_unchanged "git: dry-run conflicting 3-way merge leaves working tree clean" \
		"$git_conflict_repo/config.txt" "$conflict_before"

	# Git failed --3way MUST NOT wipe earlier applied uncommitted patches on the same file
	git_preserve_repo=$(make_git_repo "git-preserve-prior")
	preserve_patches="$tmp_dir/dp-git-preserve"
	mkdir -p "$preserve_patches"
	git -C "$git_preserve_repo" checkout -q -b bad-3way-branch
	sed -i 's/version=1.0/version=2.0/' "$git_preserve_repo/config.txt"
	git -C "$git_preserve_repo" commit -q -a -m "version 2.0"
	git -C "$git_preserve_repo" show --format= > "$preserve_patches/02-conflict.patch"
	git -C "$git_preserve_repo" checkout -q -
	sed -i 's/version=1.0/version=3.0/' "$git_preserve_repo/config.txt"
	git -C "$git_preserve_repo" commit -q -a -m "version 3.0"
	cat > "$preserve_patches/01-first.patch" << 'EOF'
--- a/config.txt
+++ b/config.txt
@@ -2,3 +2,4 @@
 version=3.0
 debug=false
 feature_x=enabled
+added_by_patch_one=true
EOF
	run_test "git: 01-first applies and 02-conflict fails (exits 1)" 1 \
		"$patch_verify" -a -r "$git_preserve_repo" "$preserve_patches"
	assert_file_contains "git: failed 02-conflict did NOT wipe 01-first's uncommitted changes" \
		"$git_preserve_repo/config.txt" "added_by_patch_one=true"
	assert_not_output "git: failed 02-conflict left no conflict markers in config.txt" \
		"<<<<<<<" cat "$git_preserve_repo/config.txt"

	# Git multi-file patch where file 1 merges cleanly and file 2 conflicts in --3way must leave BOTH files untouched
	git_multifile_repo=$(make_git_repo "git-multifile-3way")
	multifile_patches="$tmp_dir/dp-git-multifile"
	mkdir -p "$multifile_patches"
	git -C "$git_multifile_repo" checkout -q -b mf-branch
	sed -i 's/Hello World/Hello Multi/' "$git_multifile_repo/hello.c"
	sed -i 's/version=1.0/version=2.0/' "$git_multifile_repo/config.txt"
	git -C "$git_multifile_repo" commit -q -a -m "multi change"
	git -C "$git_multifile_repo" show --format= > "$multifile_patches/multifile.patch"
	git -C "$git_multifile_repo" checkout -q -
	sed -i 's/version=1.0/version=3.0/' "$git_multifile_repo/config.txt"
	git -C "$git_multifile_repo" commit -q -a -m "conflicting config change"
	mf_hello_before="$(cat "$git_multifile_repo/hello.c")"
	mf_config_before="$(cat "$git_multifile_repo/config.txt")"
	run_test "git: multi-file partial 3-way conflict exits 1" 1 \
		"$patch_verify" -a -f -r "$git_multifile_repo" "$multifile_patches"
	assert_file_unchanged "git: multi-file failed 3-way leaves hello.c untouched" \
		"$git_multifile_repo/hello.c" "$mf_hello_before"
	assert_file_unchanged "git: multi-file failed 3-way leaves config.txt untouched" \
		"$git_multifile_repo/config.txt" "$mf_config_before"

	# Git 3-way merge + --force (-f) recovers when both context and whitespace diverged
	git_3way_ws_repo=$(make_git_repo "git-3way-ws")
	threeway_ws_patches="$tmp_dir/dp-git-3way-ws"
	mkdir -p "$threeway_ws_patches"
	git -C "$git_3way_ws_repo" checkout -q -b ws3-branch
	sed -i 's/printf("Hello World\\n");/printf("Hello World\\n");\n\tprintf("3way+ws!\\n");/' "$git_3way_ws_repo/hello.c"
	git -C "$git_3way_ws_repo" commit -q -a -m "patch hello"
	git -C "$git_3way_ws_repo" show --format= | sed 's/\tprintf/    printf/g' > "$threeway_ws_patches/3way_ws.patch"
	git -C "$git_3way_ws_repo" checkout -q -
	sed -i 's/#include <stdio.h>/#include <stdio.h>\n\/\/ context shift/' "$git_3way_ws_repo/hello.c"
	git -C "$git_3way_ws_repo" commit -q -a -m "shift hello context"
	run_test "git: diverged + whitespace patch fails without -f" 1 \
		"$patch_verify" -d -r "$git_3way_ws_repo" "$threeway_ws_patches"
	run_test "git: diverged + whitespace patch passes dry-run with -d -f" 0 \
		"$patch_verify" -d -f -r "$git_3way_ws_repo" "$threeway_ws_patches"
	run_test "git: diverged + whitespace patch applies with -a -f" 0 \
		"$patch_verify" -a -f -r "$git_3way_ws_repo" "$threeway_ws_patches"

	# Git 3-way dry-run creating file in new nested directory leaves no orphaned directory behind
	git_newdir_repo=$(make_git_repo "git-3way-newdir")
	newdir_patches="$tmp_dir/dp-git-newdir"
	mkdir -p "$newdir_patches"
	git -C "$git_newdir_repo" checkout -q -b newdir-branch
	mkdir -p "$git_newdir_repo/brand_new_dir/deep"
	printf 'new file\n' > "$git_newdir_repo/brand_new_dir/deep/added.txt"
	sed -i 's/feature_x=enabled/feature_x=disabled/' "$git_newdir_repo/config.txt"
	git -C "$git_newdir_repo" add -A
	git -C "$git_newdir_repo" commit -q -m "add nested file and modify config"
	git -C "$git_newdir_repo" show --format= > "$newdir_patches/newdir.patch"
	git -C "$git_newdir_repo" checkout -q -
	sed -i 's/version=1.0/version=2.0/' "$git_newdir_repo/config.txt"
	git -C "$git_newdir_repo" commit -q -a -m "diverge config"
	run_test "git: dry-run 3-way with new nested directory exits 0" 0 \
		"$patch_verify" -d -r "$git_newdir_repo" "$newdir_patches"
	run_test "git: dry-run 3-way removes temporary newly created nested directory" 0 \
		test ! -e "$git_newdir_repo/brand_new_dir"

	# Legitimate internal relative symlink inside subdirectory is allowed in git mode
	git_intsym_repo=$(make_git_repo "git-intsym")
	intsym_patches="$tmp_dir/dp-git-intsym"
	mkdir -p "$intsym_patches"
	cat > "$intsym_patches/internal_sym.patch" << 'EOF'
diff --git a/sub/cfg_link b/sub/cfg_link
new file mode 120000
index 0000000..1234567
--- /dev/null
+++ b/sub/cfg_link
@@ -0,0 +1 @@
+../config.txt
\ No newline at end of file
EOF
	run_test "git: internal relative symlink (sub/cfg_link -> ../config.txt) allowed" 0 \
		"$patch_verify" -a -r "$git_intsym_repo" "$intsym_patches"

	# Subdirectory with bogus .git inside an outer git repo is NOT treated as git repo
	outer_repo=$(make_git_repo "git-outer")
	nested_nonrepo="$outer_repo/extracted_tarball"
	mkdir -p "$nested_nonrepo/.git"
	cp "$script_dir/source-files/"* "$nested_nonrepo/" 2> /dev/null
	nested_patches=$(make_valid_patches_dir "dp-nested-nonrepo")
	outer_hello_before="$(cat "$outer_repo/hello.c")"
	assert_output "Subdirectory with invalid .git inside outer git repo treated as non-git" "Target directory (not a git repo)" \
		"$patch_verify" -a -r "$nested_nonrepo" "$nested_patches"
	assert_file_unchanged "Outer git repo hello.c untouched when patching nested dir" \
		"$outer_repo/hello.c" "$outer_hello_before"
	assert_file_contains "Nested non-git dir hello.c patched via patch command" \
		"$nested_nonrepo/hello.c" "Patched successfully!"
fi

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
