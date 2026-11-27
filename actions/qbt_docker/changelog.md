# Changelog – `actions/qbt_docker`

## Audit & Hardening Release (2026-11-27)

Comprehensive security, correctness, and regression audit of `actions/qbt_docker/action.bash` and its unit test suite `actions/qbt_docker/test_action_bash.bash`.

---

### Regressions Fixed

1. **Re-Sourcing Failure (`readonly` Top-Level Constants)**
   - **Issue**: Declaring `container_name`, `non_root_user`, `non_root_uid`, `non_root_gid`, and `workspace` as `readonly` at top-level caused `readonly variable` errors on stderr (and immediate shell termination under `set -e` / POSIX mode) whenever `action.bash` was sourced more than once in the same shell.
   - **Fix**: Initialized default values at top-level and applied `readonly` inside the `if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then` execution guard so direct execution remains immutable while sourcing is idempotent.

2. **False-Positive Path Traversal Rejection on Filenames Containing Consecutive Dots**
   - **Issue**: `validate_input` (`dockerfile_path`) checked `[[ $input =~ \.\.|^/ ]]`, falsely rejecting valid workspace-relative filenames containing consecutive dots such as `my..Dockerfile`.
   - **Fix**: Restricted path traversal checks to actual `..` path segments (`(^|/)\.\.(/|$)`), along with leading `/`, leading `-`, and consecutive `//`.

3. **OS Detection Accuracy (`docker.io/library/...`, Org Namespaces, Attestation Entries & `DEBIAN_FRONTEND` History)**
   - **Issue**:
     - `docker buildx imagetools inspect` normalizes official image `.name` fields to `docker.io/library/<os>:<tag>` (or `docker.io/<arch>/<os>:<tag>`). `detect_os_official` matched `^[a-z0-9]+/(.*)`, failing to strip `docker.io/` (due to `.`) while mistakenly stripping arbitrary single-word namespaces (`custom/ubuntu`) as if they were official Docker Hub images.
     - In `detect_os_fallback`, `^[a-z0-9]+/(.*)` stripped real organization namespaces such as `alpine/` in `alpine/git` or `ubuntu/` in `ubuntu/squid`, misclassifying them as `unknown`.
     - Multi-arch Buildx inspection (`labels_query` / history query) inspected `.[keys[0]]` blindly, failing if an empty attestation entry sorted ahead of platform manifests (e.g., `linux/amd64`).
     - `detect_os_official` and `detect_os_fallback` lacked case-insensitive normalization (`${...,,}`), and `detect_os_fallback_with_metadata` matched `alpine|debian|ubuntu` as unanchored substrings in `.history[].created_by`, falsely classifying non-Debian images setting `ENV DEBIAN_FRONTEND=noninteractive` as `debian`.
   - **Fix**: Stripped optional `docker.io/` followed only by known official prefixes (`library` or supported arch prefixes) in both `detect_os_official` and `detect_os_fallback`, selected the first `.image` entry containing `config` or `history` in `jq` queries, applied `${...,,}` normalization across all OS detection stages, and word-bounded the history filter (`'(^|[^a-zA-Z0-9_])(alpine|debian|ubuntu)([^a-zA-Z0-9_]|$)'`) under `LC_ALL=C` so `DEBIAN_FRONTEND` does not trigger a false match.

4. **Multi-Stage, Stage-Inherited, Continuation/Heredoc-Aware & Relative `WORKDIR` Extraction in Fast-Path**
   - **Issue**: Fast-path `WORKDIR` parsing (`grep ... | tail -1 | sed ...`) took the last `WORKDIR` line across the entire Dockerfile regardless of stage boundaries—leaking a discarded builder stage's `WORKDIR` into `wd` when the final `FROM` stage omitted `WORKDIR`—failed to resolve sequential relative `WORKDIR` instructions (`WORKDIR /opt` followed by `WORKDIR app`), and did not join `\`-continued `FROM`/`RUN` instructions or skip BuildKit `<<EOF` heredoc bodies (where inline scripts may contain lines starting with `FROM` or `WORKDIR`).
   - **Fix**: Implemented `extract_dockerfile_workdir` in pure Bash to join unescaped trailing-backslash line continuations (preserving continuations across embedded `#` comment lines), skip BuildKit `<<EOF` / `<<-EOF` heredoc bodies, match valid Dockerfile `FROM [--opt=val] <image> [AS <name>]` stage headers, safely inherit `WORKDIR` when a stage builds `FROM <earlier_stage_alias>` (validating `^[a-z0-9._-]+$` before associative-array subscript lookup to prevent subscript errors or injection), and resolve sequential absolute/relative `WORKDIR` paths per Docker semantics.

5. **Silent Loss of Final Line, CRLF Corruption & Whitespace-Only Line Errors in `sanitize_env_file`**
   - **Issue**: `sanitize_env_file` used `while IFS= read -r line` without `|| [[ -n $line ]]` (silently dropping the final variable in `env.custom` when no trailing newline was present), did not strip `\r` on Windows CRLF (`\r\n`) files, and emitted false `[ERROR] Security: Invalid environment variable blocked` messages on whitespace-only lines (`"    "`).
   - **Fix**: Added `_sanitize_env_stream` using `while IFS= read -r line || [[ -n $line ]]`, stripped trailing `\r`, and skipped whitespace-only lines (`[[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]]`).

---

### Security Fixes

1. **Locale- & `IFS`-Independent Validation (`local LC_ALL=C` / `local IFS`)**
   - **Issue**: Under UTF-8 dictionary collation locales such as `en_US.UTF-8` on standard Linux runners, POSIX ERE character ranges `[a-z]` and `[A-Za-z]` in `[[ ... =~ ... ]]` match uppercase letters (`A`–`Y` fall inside `[a-z]`, allowing `inputs_platform="LINUX/AMD64"`) as well as non-ASCII accented characters (`cürl`, `ÉVIL=1`), while `validate_docker_commands` and `parse_app_list` relied on caller `IFS` when sourced.
   - **Fix**: Scoped `local LC_ALL=C` inside all validation, command-parsing, `WORKDIR`, and OS-detection functions, and scoped `local IFS=$' \t\n'` inside `validate_docker_commands` and `parse_app_list`, enforcing deterministic ASCII matching and whitespace splitting without mutating caller `LC_ALL` or `IFS` when sourced.

2. **Per-Flag Value Validation in `parse_docker_commands` (Closing `-e`/`--env` Blocklist Bypass, Rootfs Mounts & Flag Smuggling)**
   - **Issue**: `parse_docker_commands` previously validated only the leading flag token and `$` / `` ` `` characters, allowing:
     - Blocked loader/shell/runner variables via `--env LD_PRELOAD=/evil.so`, `-e BASH_ENV=/evil.sh`, `-e PATH=/evil`, or `-e GITHUB_ENV=/evil` (bypassing `check_env_var`).
     - Valueless `-e SECRET_VAR` flags, which instruct `docker run` to inherit host runner environment variables into the container even when `inputs_use_host_env=false`.
     - Docker daemon socket mounts (`--volume /var/run/docker.sock:/var/run/docker.sock` or `/var/run/docker.sock/:/s`), host root-filesystem bind mounts (`--volume /:/host`), relative container destinations (`--volume /tmp:rel`), `..` path traversal, or extra flags smuggled on a single line (`--volume /tmp:/tmp --privileged`).
     - Silent fail-open skipping if a non-empty line failed to match the option regex.
   - **Fix**: Enforced fail-closed matching and validated every expanded flag value via `validate_input`:
     - `-e` / `--env`: `env_var` (`check_env_var` format, character, and blocklist enforcement).
     - `-v` / `--volume`: `docker_volume` (requires `src:/abs_dst[:opts]` or `/abs_anon`, blocks whitespace, leading `-`, host rootfs `^/+:`, `:/$`, `..` traversal segments, and `docker.sock` mounts with or without trailing `/`).
     - `-u` / `--user`: `docker_user` (`uid[:gid]` / `user[:group]`).
     - `-w` / `--workdir`: `docker_workdir` (absolute container path without `..` segments).
     - `--memory`: `docker_memory` (`^[1-9][0-9]*[bBkKmMgG]?$`).
     - `--cpus`: `docker_cpus` (positive integer or decimal CPU limit).

3. **Multiline Environment Injection Fix, Extended Loader/Shell Blocklist & Comprehensive Secret Redaction**
   - **Issue**:
     - In Bash regex matching (`[[ $input =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]`), `.` matches `\n`, allowing multiline strings such as `$'SAFE=1\nLD_PRELOAD=/evil.so'` or `$'SAFE=1\nPATH=/evil'` to pass `check_env_var`, `to_gh_env`, and `to_gh_output`.
     - Blocked environment variable diagnostics printed full `KEY=VALUE` strings to stderr, while `_inputs_info` (`GITHUB_STEP_SUMMARY` and stdout) and `docker run` failure logs printed `${clean_envs[*]}` with plaintext `-e` / `--env` secret values.
   - **Fix**:
     - Explicitly rejected `\n` and `\r` in `check_env_var` and extended the blocklist with `SHELLOPTS`, `BASHOPTS`, `GLIBC_TUNABLES`, `GCONV_PATH`, and `GITHUB_STATE`.
     - Added `redact_env_var` and `format_clean_envs_for_log` so blocked-env logs, step summaries (`_inputs_info`), and both fast-path and standard-path `docker run` error messages report `KEY=<redacted>` without exposing secret values.

4. **Workspace & Runner File Symbolic Link Protection, Build-Context Secret Isolation & `0600` Env Permissions**
   - **Issue**:
     - Fast-path `[[ -f "$workspace/$inputs_dockerfile" ]]` and `cp` followed symbolic links (both leaf symlinks and symlinked subdirectories) and emitted the copied file to stdout and `$GITHUB_STEP_SUMMARY` before `docker build`, allowing a repository symlink to disclose arbitrary host files.
     - `${workspace}/env.custom` also followed symlinks; pre-existing symlinks or directory/parent-dir errors on `${workspace}/env.host`, `${workspace}/qbt_builder_dockerfile`, `GITHUB_ENV`, `GITHUB_OUTPUT`, and `GITHUB_STEP_SUMMARY` were not guarded upfront (risking symlink clobbering or post-`docker run` failures leaving orphaned containers); and `env.host` / `env.load` were created with default world-readable permissions before `docker build` ran (exposing raw host secrets in the `"$workspace"` Docker build context if a custom Dockerfile ran `COPY .` and leaving `env.host` on disk if `docker build` failed).
   - **Fix**:
     - Added `validate_workspace_file` (using pure-Bash parent resolution and `cd -P` / `pwd -P`) to reject symbolic links along any path component and verify physical containment within `$workspace`.
     - Added `validate_environment_paths` and `validate_gh_file_target` upfront before building or starting containers, rejecting symlinks, directory collisions, unreadable `env.custom`, and missing parent directories across workspace env files and `GITHUB_ENV` / `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY`.
     - Deferred `process_environment` until after `docker build` succeeds (and after temporary Dockerfile cleanup), eliminated intermediate `.safe` disk files by streaming directly into `env.load`, unlinked `env.host` and `qbt_builder_dockerfile` prior to creation (preserving `inputs_dockerfile` via `-ef` when it already points to `qbt_builder_dockerfile`), and wrote `env.host` and `env.load` under `umask 077` (`0600`).

5. **CLI Flag Injection, Absolute Workspace Enforcement & `WORKDIR` Traversal Prevention**
   - **Issue**:
     - `validate_input` (`package_name`) allowed leading hyphens (`--allow-untrusted`, `-o ...`) interpolated into `apk add` and `apt-get install`.
     - `inputs_os_id`, arch-prefixed `image_name`, and `inputs_os_version_id` allowed leading hyphens (`-f`), leading/trailing `/`, `//`, or `..` segments, and `docker buildx imagetools inspect` passed `"$image"` without `--`.
     - Relative `GITHUB_WORKSPACE` values (e.g., `relative_dir`) caused `docker run -v "$workspace:$wd"` to mount an empty named Docker volume instead of bind-mounting the workspace, while fast-path `extracted_wd` previously permitted `..` traversal paths.
   - **Fix**:
     - Required leading ASCII alphanumeric `[a-zA-Z0-9]` on `package_name`, valid OCI repository syntax on `inputs_os_id` / `image_name`, and leading `[a-zA-Z0-9_]` on `inputs_os_version_id`; passed `--` before `"$image"` in `docker buildx imagetools inspect`.
     - Enforced that `$workspace` is an existing absolute directory (`/*`) containing no `:`, `\n`, or `\r`.
     - Blocked `(^|/)\.\.(/|$)` traversal segments in `extract_dockerfile_workdir` (retaining default `/home/gh` with a security warning).

---

### Code & Reliability Fixes

1. **Shell Operator Precedence, `bash` Availability & Home Directory Consistency in Standard Dockerfiles**
   - **Issue**:
     - In `generate_standard_dockerfile` (`"unknown" | *`), `if ...; fi && groupadd ... || addgroup ... || true && ...` evaluated left-to-right: if `apt-get` or `apk` failed, `|| addgroup ... || true` executed and reset the exit status to `0`, masking package installation failures during `docker build`.
     - The fallback `apk` branch installed `sudo` without `bash` while configuring `-s /bin/bash` on `adduser`, leaving `/bin/bash` missing on Alpine-derived images whose OS was not detected, and `useradd` omitted explicit `-d ${wd}` home directory alignment with `adduser -h ${wd}`.
   - **Fix**: Grouped `{ groupadd ... || addgroup ... || true; }` and `{ useradd ... || adduser ... || true; }`, added `bash` to both fallback package install branches, passed `-d ${wd}` to `useradd`, and ensured `/etc/sudoers.d` exists via `mkdir -p /etc/sudoers.d`.

2. **`docker build` Context Directory, Unset GitHub Runner File Vars, Direct Writes & Error Propagation**
   - **Issue**:
     - Both fast-path and standard `docker build` passed `.` (`$PWD`) instead of `"$workspace"` as build context, breaking workspace-relative `COPY`/`ADD` instructions whenever `$PWD != $GITHUB_WORKSPACE`.
     - Running outside GitHub Actions with unset/empty `GITHUB_ENV`, `GITHUB_OUTPUT`, or `GITHUB_STEP_SUMMARY` failed with `ambiguous redirect` or `tee: '': No such file or directory`.
     - Standard-path Dockerfile generation piped through `tee "$dockerfile_path" | tee -a "$GITHUB_STEP_SUMMARY"` (masking write errors to `$dockerfile_path`), `_env_info` ignored per-line `to_gh_env`/`to_gh_output` failures (and fast-path unconditionally followed `_env_info` with `exit 0`), `process_environment` ignored `env.load` write errors, 0-byte fast-path Dockerfiles left temporary `qbt_builder_dockerfile` behind, and missing `docker` CLI was not checked upfront.
   - **Fix**:
     - Passed `"$workspace"` as the `docker build` context in both paths and checked `command -v docker` upfront.
     - Guarded `GITHUB_ENV`, `GITHUB_OUTPUT`, and `GITHUB_STEP_SUMMARY` writes when unset, replaced all `tee -a` pipelines on runner files with checked `>>` appends, wrote `"$dockerfile_path"` directly with explicit `-s` verification, checked exit codes on all `env.load`, `GITHUB_STEP_SUMMARY`, and `_env_info` writes, and cleaned up temporary Dockerfiles on empty-file or build failure.
     - Replaced external `printf | tr` and `dirname` forks with pure-Bash parameter expansion, extended remote/URI rejection in fast-path (`ftp://`, `git://`, `ssh://`, `file://`), and aligned top-of-file comments with actual script behavior.

3. **Validated Baseline Hardening Retained**
   - Preserved `RUNNER_ARCH` and arch-prefixed image platform auto-detection with explicit `inputs_platform` precedence, single `--platform` flag emission, `--cap-drop ALL` with minimal capability grants (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`), `-u 1001:1001` non-root container execution when `inputs_use_root=false`, safe `$wd` / `${wd}` boundary expansion in `parse_docker_commands`, stale `env.load` cleanup, and `env -0` NUL-delimited host environment capture.

---

### Unit Test Suite (`actions/qbt_docker/test_action_bash.bash`)

- **Fixed Masked, Coupled & Vacuous Assertions**:
  - Updated `OS Detection via Buildx Metadata (jq)` tests to use OS-neutral image names (`ghcr.io/userdocs/qbt-nox`, `ghcr.io/userdocs/qbt-custom`, `custom/myimage`) instead of `qbt-debian`, `qbt-ubuntu`, and `mydebian`, which previously allowed `detect_os_fallback` name parsing to mask broken `jq` metadata queries.
  - Hardened `assert_not_dockerfile` and `assert_dockerfile` to verify `${tmp_dir}/last_dockerfile` exists before grepping, added `--` option terminators across `grep` helpers, ensured build-context assertions invoke their own setup explicitly, and verified command exit codes / `docker run` execution in negative assertions (`PATH=`, `LD_PRELOAD=`, `env.host` ignored, `inputs_use_root=true`).
- **Expanded Coverage (96 -> 166 Assertions Passing)**:
  - **Locale, `IFS` & Input Validation**: UTF-8 locale collation regression tests (`LINUX/AMD64` and non-ASCII `cürl` under UTF-8 locale, plus caller `LC_ALL` and custom `IFS` preservation when sourced), leading-hyphen flag injection on `inputs_os_id`, arch-prefixed `inputs_os_id`, `inputs_os_version_id`, and `inputs_additional_apps` (`--allow-untrusted`), `..` segment rejection on `inputs_os_id`, colon and relative workspace rejection, `i386/alpine -> linux/i386`, valid `+`/`.`/`-` package names, and symlink/directory/missing-parent checks on `GITHUB_ENV` / `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY` before `docker` runs.
  - **Fast-Path Dockerfile & `WORKDIR`**: `file://` URI rejection, consecutive-dot filenames (`my..Dockerfile`), `-ef` preservation when `inputs_dockerfile="qbt_builder_dockerfile"`, symlinked `inputs_dockerfile` and symlinked parent directory rejection with non-disclosure verification, empty Dockerfile cleanup, path-traversing `WORKDIR`, sequential relative `WORKDIR`, multi-stage `WORKDIR` isolation and `FROM <alias>` inheritance, multiline `FROM \` + BuildKit `<<HEREDOC` and inline `from ...` immunity, bracket/command `FROM` subscript-injection safety, and `$workspace` build context verification.
  - **OS Detection & Dockerfile Generation**: `alpine/git` and `ubuntu/squid` org-prefixed image detection, `docker.io/library/debian:bookworm` `.name` detection, multi-arch Buildx JSON skipping leading empty attestation entries, `DEBIAN_FRONTEND` history false-positive immunity, and unknown-OS fallback command grouping and `bash` installation.
  - **Environment & Custom Docker Flags**: CRLF + missing trailing newline and whitespace-only lines in `env.custom`, `env.load` directory collision rejection, extended loader/shell/`GITHUB_STATE` blocklist, secret value redaction in blocked-env logs, step summaries (`_inputs_info`), and `docker run` error logs, symlinked `env.custom` rejection, `env.host` symlink clobber protection + `0600` file mode verification, non-creation of `env.host` on failed validation or failed fast-path/standard `docker build`, blocked `--env LD_PRELOAD`, `-e PATH`, valueless `-e HOME`, `docker.sock` and `docker.sock/` mounts, host rootfs `/:/host` and relative container destination mounts, smuggled extra flags (`--volume /tmp:/tmp --privileged`), `--workdir` traversal, zero `--memory`/`--cpus`, and valid `-u`/`-w`/`:ro`/decimal `--cpus`.
  - **Sourcing & Execution Resilience**: Multiline `to_gh_env` / `to_gh_output` rejection, idempotent double-sourcing under `set -e` with stderr capture, execution with unset `GITHUB_*` file variables, and missing `docker` binary handling.
  - Static validation passing with zero warnings/diffs under `bash -n`, `shellcheck -s bash`, and `shfmt -d -s -bn -ci -sr -i 0`.
