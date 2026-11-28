# Changelog – `musl-cross-make/patch_verify`

## Security, Correctness & Reliability Audit (2026-11-27)

Consolidated audit of `musl-cross-make/patch_verify` and `musl-cross-make/test-suite/run_tests.bash`.

---

### Security Fixes

1. **Stateful Diff Header & Symbolic Link Validation (`validate_patch_security` / `check_patch_target_path`)**
   - Replaced stateless whole-file regex matching with a pure-Bash hunk-aware parser that tracks `@@ -old +new @@` line counts to skip hunk bodies (` `, `-`, `+`, `\`), eliminating false-positive rejections on hunk lines such as Ada/SQL `-- ... .. ...` comments while inspecting all diff headers (`diff --git`, `---`, `+++`, `rename from/to`, `copy from/to`).
   - Decoded C-quoted octal path escapes (`\056`/`\56`, `\057`/`\57`) with or without `<TAB>` timestamps and stripped CRLF line endings; blocked `..` path-segment traversal (while permitting consecutive dots inside filenames such as `foo..bar.txt`) and non-`/dev/null` absolute or trailing-slash target paths.
   - Validated Git symlink entries (`new file mode 120000` / `new mode 120000`) via relative directory depth calculation—blocking absolute and escaping relative symlinks while permitting intra-tree relative symlinks (`sub/cfg_link -> ../config.txt`)—and blocked intra-patch two-step symlink writes as well as on-disk symlink directory/file traversal in non-git `patch` mode.

2. **Strict Git Worktree Root Verification (`is_git_repo_root`)**
   - Verified `git -C "$dir" rev-parse --show-toplevel` matches the physical target path (`cd -P -- "$dir" && pwd -P`) alongside `[[ -e $dir/.git ]]`, supporting standard repositories, linked worktrees, and submodules while preventing nested non-repo subdirectories with stray `.git` entries from walking up and patching an enclosing parent repository.

3. **Output Path, Tool Pre-Flight & Option Terminator Hardening**
   - Guarded `--save-failed` (`-s`) against symbolic links and non-regular files (directories, FIFOs) while preserving `/dev/null`, and removed stale `--save-failed` files when subsequent runs succeed.
   - Verified `command -v patch` before processing non-git targets so missing `patch` binaries fail immediately rather than marking every patch failed and deleting patches under `--delete-failed` (`-x`).
   - Added `--` option terminators on `git apply` and `rm`/`cp`/`mkdir` calls and `printf '%q'` escaping in verbose recovery commands.

4. **Deterministic Locale & `IFS` Scoping**
   - Scoped `local LC_ALL=C` and `local IFS=$' \t\n'` inside `apply_patches` and `validate_patch_security`, and localized `IFS='/'` on `read -ra`, ensuring deterministic ASCII patch glob ordering and regex matching without mutating caller shell state when sourced.

---

### Bug & Regression Fixes

1. **Idempotent Sourcing & Local Variable Isolation**
   - Kept `#!/bin/bash` shebang and `${BASH_SOURCE[0]}` execution guard, avoided `readonly` on top-level color definitions so `patch_verify` can be re-sourced under `set -e` without `readonly variable` errors, validated boolean parameters in `apply_patches`, and scoped internal validation state (`patch_security_error`, `checked_rel_path`) locally.

2. **Caller `PWD` Preservation & Unified Patch Ordering**
   - Replaced directory-changing `cd` logic with `git -C "$git_repo"` and `patch -d "$git_repo"` so caller `PWD` is never mutated, and collected `.patch` and `.diff` files in a single lexicographical pass so mixed-extension patch series (`01.diff`, `02.patch`) apply in order.

3. **Transactional Git 3-Way Merge & Dry-Run Parity (`git_try_3way`)**
   - Snapshotted affected paths and `.git/index` around `git apply --3way` (using pure-Bash parent directory expansion without external `dirname` forks) so dry-run checks detect 3-way mergeability and failed or partial multi-file 3-way merges roll back conflict markers, index stages, and newly created nested directories without wiping prior uncommitted changes; forwarded `--ignore-whitespace` when `--force` (`-f`) is enabled.

4. **Atomic Non-Git Patch Application & Accurate Diagnostics**
   - Verified non-git patches with `patch --batch --forward --no-backup-if-mismatch -r - --dry-run -p1` before applying (preventing reverse-application, partial multi-hunk mutations, and `.orig`/`.rej` clutter), captured errors from the apply step when `--dry-run` succeeds and writing fails, added `--verbose` diagnostics to failed Git dry-runs, and replaced `sed` indentation pipes with pure-Bash parameter expansion.

5. **File Accessibility, Non-Interactive Deletion & CLI Parsing**
   - Rejected inaccessible patch directories, unreadable patch files (`Patch file is not readable`), and 0-byte patch files (`Patch file is empty`, which GNU `patch` otherwise accepts with exit code `0`).
   - Used `rm -f --` in `--delete-failed` (`-x`) after `[[ -f $patch_path ]]` so write-protected (`0444`) failing patches never hang waiting on interactive TTY stdin.
   - Added `--` end-of-options, `--repo=DIR`, `--save-failed=FILE`, and `-[davfx]?*` short-option clustering with single-point `--save-failed` parent-directory validation.

---

### Unit Test Suite (`musl-cross-make/test-suite/run_tests.bash`)

- Enforced exit code `0` in `assert_output` and exit code `1` in `assert_fail_output` so output assertions cannot pass on unexpected exit codes, verified `set -e` double-sourcing with empty stderr and caller `IFS`/`LC_ALL` preservation, and isolated target directory variables across sections (`ws_apply_target`).
- Expanded valid, non-vacuous coverage to **120 assertions** covering CLI parsing, dry-run/apply parity, transactional 3-way merges (diverged context, `--force` whitespace, multi-file conflicts, uncommitted preservation, nested directory cleanup), worktree and nested `.git` detection, hunk-body `-- ..` and `foo..bar.txt` non-regression, octal/rename/absolute/symlink security protections, `--save-failed` symlink/directory guards, `0444` `-x` deletion, unreadable/empty patches, and static analysis (`bash -n`, `shellcheck -s bash`, `shfmt -d -s -bn -ci -sr -i 0`).
