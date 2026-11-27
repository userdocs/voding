# Changelog – `musl-cross-make/patch_verify`

## Audit & Hardening Release (2026-11-27)

Comprehensive security, correctness, and regression audit of `musl-cross-make/patch_verify` and its unit test suite `musl-cross-make/test-suite/run_tests.bash`.

---

### Regressions Fixed

1. **Library Re-Sourcing Failure (`readonly` Global Color Variables)**
   - **Issue**: Marking top-level `color_*` and `text_bold` variables `readonly` caused `readonly variable` errors on stderr (and non-zero return codes under `set -e` / POSIX mode) whenever `patch_verify` was sourced more than once or sourced in a shell already using those common variable names.
   - **Fix**: Removed `readonly` from top-level color definitions while scoping internal validation state (`patch_security_error`, `checked_rel_path`) as `local` variables so sourcing and calling `apply_patches` is idempotent and leak-free.

2. **False-Positive Path Traversal Rejections on Unified Diff Hunk Content**
   - **Issue**: The previous `patch_has_path_traversal` regex scanned every line of the patch file indiscriminately (`^(\+\+\+|---|diff --git )[[:space:]]...`). Any legitimate patch removing or adding lines starting with `-- ` or `++ ` that also contained `..` (for example, GCC Ada comments such as `--  Check range 1 .. 10`, serialized in unified diff as `---  Check range 1 .. 10`) was falsely rejected as a path traversal attack—and deleted when `--delete-failed` (`-x`) was enabled.
   - **Fix**: Replaced the stateless `grep` check with a stateful, pure-Bash diff parser (`validate_patch_security`) that tracks active hunk line counts (`@@ -old_start[,old_count] +new_start[,new_count] @@`) and skips hunk body lines (` `, `-`, `+`, `\`) when inspecting file headers.

3. **False-Positive Rejection of Filenames Containing `..` in `git_try_3way`**
   - **Issue**: `git_try_3way` rejected paths matching `[[ $p == *..* ]]`, breaking patches targeting valid filenames containing consecutive dots (such as `foo..bar.txt`).
   - **Fix**: Restricted path checks to actual `..` path components (`..`, `../*`, `*/../*`, `*/..`) and deduplicated multi-hunk/multi-commit path lists via `seen_paths`.

4. **Orphaned Nested Directories After Git 3-Way Dry-Run or Failed Merge**
   - **Issue**: When a 3-way patch created a file inside a new nested directory (e.g., `brand_new_dir/deep/added.txt`), rollback in `git_try_3way` deleted only the leaf file path, leaving newly created parent directories behind in the target repository even during `--dry-run`.
   - **Fix**: Walked upward from non-existent target paths to record the highest missing ancestor directory inside `$git_repo` in `created_paths`, ensuring full directory tree cleanup on dry-run or failed 3-way rollback.

5. **`--force` (`-f`) Ignored During Git 3-Way Merge Fallback**
   - **Issue**: `git_try_3way` did not forward `--ignore-whitespace` when `--force` (`-f`) was active, causing patches that required both 3-way context resolution and whitespace tolerance to fail in both dry-run and apply modes.
   - **Fix**: Forwarded `$force` to `git_try_3way` so `--ignore-whitespace` is included with `git apply --3way` when requested.

6. **Inconsistent 2-Character Short Option Cluster Diagnostics**
   - **Issue**: The short-option cluster pattern `-[davfx][davfx]*` bypassed the per-flag cluster parser on 2-character clusters with an invalid second flag (e.g., `-az`), making per-character error reporting unreachable for 2-character inputs.
   - **Fix**: Updated the pattern to `-[davfx]?*` so any multi-character short cluster starting with a valid flag reports the exact invalid character (`Unknown option: -z (in -az)`).

---

### Security Fixes

1. **Comprehensive Header & Symbolic Link Validation (`validate_patch_security` / `check_patch_target_path`)**
   - Implemented in pure Bash (zero external `grep`/`awk`/`sed` forks per patch; CRLF-safe):
     - **Octal-Escaped Quoted Headers**: Decodes C-quoted octal path escapes (`\056` / `\56` for `.` and `\057` / `\57` for `/`), including headers followed by `<TAB>` timestamps (`--- "a/\056\056/..."	2026-01-01`).
     - **Extended Git Rename/Copy Headers**: Validates `rename from`, `rename to`, `copy from`, and `copy to` paths (which omit `a/`/`b/` prefixes and can spoof `diff --git` headers in `patch --dry-run`).
     - **Absolute Target Paths**: Rejects non-`/dev/null` header paths starting with `/` (or resolving to `/*` after `-p1` stripping).
     - **Escaping Git Symlinks (`mode 120000`)**: Tracks `new file mode 120000` / `new mode 120000` entries and verifies symlink targets neither start with `/` nor traverse above the target root via relative depth calculation—blocking escaping symlinks while permitting valid intra-repository relative symlinks (e.g., `sub/cfg_link -> ../config.txt`).
     - **Intra-Patch & On-Disk Symlink Traversal**: Blocks two-step patches that create a symlink and write beneath it in the same patch, blocks target paths traversing pre-existing symbolic link directories on disk (closing a gap where `patch --dry-run` exited `0` when creating files beneath a symlinked directory), and blocks patching symbolic link files directly in non-git mode.

2. **`--save-failed` (`-s`) Symbolic Link Clobber Protection**
   - Refuses to write failed patch lists when the destination path is a symbolic link (`[[ -L $output_file ]]`), preventing symlink clobber attacks in shared directories (such as `-s /tmp/fails.list`), and suppresses raw shell redirection stderr noise on invalid/directory targets.

3. **Strict Git Worktree Root Detection (`is_git_repo_root`)**
   - Verified `git -C "$dir" rev-parse --show-toplevel` matches the physical target path (`cd "$dir" && pwd -P`) in addition to `[[ -e $dir/.git ]]`. Prevents target subdirectories containing an empty or corrupt `.git` entry inside an outer git repository from walking up to the parent repository and applying patches to the wrong tree, while continuing to support standard repositories, linked worktrees, and submodules.

---

### Code & Reliability Fixes

1. **Empty (0-Byte) Patch File Rejection**
   - Added an explicit `[[ ! -s $patch_file ]]` check (`Patch file is empty`). Previously, GNU `patch` exited `0` (`OK` / `Applied`) on 0-byte `.patch` files in non-git directories while `git apply` failed with exit code `128`.

2. **Accurate Error Reporting When Non-Git Apply Fails After `--dry-run` Passes**
   - Captured output from the real `patch` invocation into `apply_err` instead of discarding it to `/dev/null`. When `--dry-run` succeeds (`checking file ...`) and the subsequent write fails (e.g., read-only target directory or file permissions), `Reason:` now reports the actual apply error rather than `checking file ...`.

3. **Non-Interactive `--delete-failed` (`-x`) on Write-Protected Patch Files**
   - Changed `rm -- "$patch_path" 2> /dev/null` to `rm -f -- "$patch_path" 2> /dev/null` after verifying `[[ -f $patch_path ]]`. Prevents `rm` from hanging indefinitely waiting for interactive TTY confirmation while its prompt is hidden by stderr redirection when a failing patch file has `0444` permissions.

4. **Verbose Git Dry-Run Diagnostics, Built-In Formatting & CLI Cleanup**
   - Added `git -C "$git_repo" apply --check --verbose` diagnostics on failed Git dry-runs when `-v` (`--verbose`) is enabled.
   - Replaced external `| sed 's/^/      /'` pipelines with pure-Bash parameter expansion (`${error_message//$'\n'/$'\n      '}`).
   - Deduplicated the `--save-failed` missing-parent-directory warning into a single post-parse check and updated the `--help` description of `-f, --force` to accurately reflect `(ignore whitespace)`.

5. **Validated Baseline Hardening Retained**
   - Preserved caller working directory (`git -C` / `patch -d` without mutating `PWD`), lexicographical `.patch`/`.diff` ordering, pre-flight `patch` binary verification prior to `-x` deletion, `--batch --forward --no-backup-if-mismatch -r -` flags preventing `.orig`/`.rej` artifacts and reverse-application, transactional `git_try_3way` preserving prior uncommitted changes, stale `--save-failed` file cleanup when all patches pass, boolean parameter validation in `apply_patches`, `--repo=` / `--save-failed=` / `--` CLI parsing, and `printf '%q'` escaping in verbose recovery commands.

---

### Unit Test Suite (`musl-cross-make/test-suite/run_tests.bash`)

- **Fixed Fragile Test State Coupling**: Replaced implicit reliance on `$target` across distant sections for the `.orig` backup check with an explicit `ws_apply_target` directory variable, and added content assertions verifying both local and incoming changes after a Git 3-way merge.
- **Expanded Coverage (119+ Assertions Passing)**:
  - Library re-sourcing idempotency and absence of leaked helper globals (`patch_security_error`, `checked_rel_path`).
  - Hunk body `-- ..` lines (Ada/SQL comment false-positive regression) and filenames containing `..` (`foo..bar.txt`).
  - C-quoted octal path traversal (both plain and with `<TAB>` timestamps), spoofed `rename to` traversal, absolute header paths, pre-existing symlink directory traversal, `mode 120000` escaping symlinks, intra-patch two-step symlink writes, and allowed internal relative symlinks (`sub/cfg_link -> ../config.txt`).
  - `--save-failed` symlink target protection, `--delete-failed` removal of `0444` read-only patches, read-only target apply error reporting, and 0-byte patch rejection.
  - 2-character short-flag cluster error diagnostics (`-az`), Git 3-way + `--force` whitespace merges, Git 3-way nested directory cleanup on dry-run, and nested invalid `.git` directory isolation inside an outer repository.
  - Static validation via `bash -n`, `shellcheck -s bash`, and `shfmt -d -s -bn -ci -sr -i 0`.
