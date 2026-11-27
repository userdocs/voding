# Changelog – `actions/qbt_docker`

## Audit & Hardening Release (2026-11-27)

Comprehensive security, correctness, and regression audit of `actions/qbt_docker/action.bash` and its unit test suite `actions/qbt_docker/test_action_bash.bash`.

---

### Regressions Fixed

1. **Re-Sourcing Failure (`readonly` Top-Level Constants)**
   - **Issue**: Declaring `container_name`, `non_root_user`, `non_root_uid`, `non_root_gid`, and `workspace` as `readonly` at top-level caused `readonly variable` errors on stderr (and immediate shell termination under `set -e` / POSIX mode) whenever `action.bash` was sourced more than once in the same shell.
   - **Fix**: Initialized default values at top-level and applied `readonly` inside the `if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then` execution guard so direct execution remains immutable while sourcing is idempotent.

2. **False-Positive Path Traversal Rejection on Consecutive Dots & Trailing-Slash `dockerfile_path` Tightening**
   - **Issue**: `validate_input` (`dockerfile_path`) checked `[[ $input =~ \.\.|^/ ]]`, falsely rejecting valid workspace-relative filenames containing consecutive dots such as `my..Dockerfile`, while accepting bare `.` and trailing slashes (`my.Dockerfile/`) that slipped past `IFS='/'` splitting in `validate_workspace_file` and later failed `stat` with `ENOTDIR`.
   - **Fix**: Restricted path traversal checks to actual `..` path segments (`(^|/)\.\.(/|$)`), and blocked bare `.`, leading `/`, trailing `/`, leading `-`, and consecutive `//` in both `validate_input` and `validate_workspace_file` (including standalone `..` segment rejection inside `validate_workspace_file`).

3. **OS Detection Accuracy (Target Platform Selection, `docker.io/library/...`, Ported Registries, `@sha256` Digests, Org Namespaces, Attestation Entries & Word-Bounded History Extraction)**
   - **Issue**:
     - `docker buildx imagetools inspect` normalizes official image `.name` fields to `docker.io/library/<os>:<tag>` (or `@sha256:...`). `detect_os_official` matched `^[a-z0-9]+/(.*)`, failing to strip `docker.io/` (due to `.`) while mistakenly stripping arbitrary single-word namespaces (`custom/ubuntu`), and did not strip `@sha256:...` digests when `:tag` was absent.
     - In `detect_os_userdocs`, `base.name` stripped `%%:*` before `##*/`, breaking port-qualified registries (`registry.local:5000/library/ubuntu:24.04`) and `@sha256:...` digest references.
     - In `detect_os_fallback`, `^[a-z0-9]+/(.*)` stripped real organization namespaces such as `alpine/` in `alpine/git` or `ubuntu/` in `ubuntu/squid`, misclassifying them as `unknown`, and did not strip `@sha256:...` digests before splitting.
     - Multi-arch Buildx inspection (`labels_query` / history query) inspected `.[keys[0]]` blindly instead of preferring the requested `$inputs_platform` entry (including OCI `linux/arm64` <-> `linux/arm64/v8` variant normalization) and skipping empty attestation manifests.
     - `detect_os_official` and `detect_os_fallback` lacked case-insensitive normalization (`${...,,}`), and `detect_os_fallback_with_metadata` matched `alpine|debian|ubuntu` as unanchored substrings in `.history[].created_by` (and even after word-bounding `grep`, matched the returned full line with unanchored `*alpine*` / `*debian*` / `*ubuntu*` `case` globs, misclassifying lines like `ALPINE_MIRROR=none apt-get install -y debian-archive-keyring`).
   - **Fix**: Added shared `_jq_image_selector` with `--arg plat "${inputs_platform:-}"` to prefer `.[$plat]` (and the `linux/arm64` <-> `linux/arm64/v8` OCI variant alias) when present while falling back to the first `.image` entry containing `config` or `history`; stripped `@*` digest, `##*/` path prefix, and `%%:*` tag in the proper sequence across `detect_os_userdocs`, `detect_os_official`, and `detect_os_fallback`; stripped optional `docker.io/` followed only by known official prefixes (`library` or supported arch prefixes) in `detect_os_official` and `detect_os_fallback`; applied `${...,,}` normalization across all OS detection stages; and extracted the exact word-bounded OS match via `BASH_REMATCH[2]` (`(^|[^a-z0-9_])(alpine|debian|ubuntu)([^a-z0-9_]|$)`) under `LC_ALL=C`.

4. **Multi-Stage, Stage-Inherited, Continuation/Heredoc-Aware & Dot-Normalized `WORKDIR` Extraction in Fast-Path**
   - **Issue**: Fast-path `WORKDIR` parsing (`grep ... | tail -1 | sed ...`) took the last `WORKDIR` line across the entire Dockerfile regardless of stage boundaries—leaking a discarded builder stage's `WORKDIR` into `wd` when the final `FROM` stage omitted `WORKDIR`—failed to resolve sequential relative `WORKDIR` instructions (`WORKDIR /opt` followed by `WORKDIR app`) or normalize `.` segments (`WORKDIR .`, `WORKDIR /opt/./app`), and did not handle `\`-continued instructions (including dangling `\` at EOF) or BuildKit `<<EOF` heredoc bodies without misinterpreting `<<<` here-strings or `<<` bitshift expressions.
   - **Fix**: Implemented `extract_dockerfile_workdir` in pure Bash to join odd-count trailing-backslash continuations (preserving continuations across `#` comments and flushing dangling continuations at EOF), skip BuildKit `RUN` (including piped/chained `| sh`, `&&`, `;`, and fd redirects) and `COPY`/`ADD` `<<EOF` / `<<-EOF` heredoc bodies across both relative and absolute destinations (while excluding `<<<` here-strings and mid-expression `<<` bitshifts), match valid Dockerfile `FROM [--opt=val] <image> [AS <name>]` stage headers, safely inherit `WORKDIR` when a stage builds `FROM <earlier_stage_alias>` (validating `^[a-z0-9._-]+$` before associative-array subscript lookup to prevent subscript errors or injection), and resolve sequential absolute/relative `WORKDIR` paths while collapsing `//`, `/./`, and trailing `/.` segments per Docker `filepath.Clean` semantics.

5. **Silent Loss of Final Line, CRLF Corruption, Whitespace-Only Line Errors & Multiline `env -0` Exit Status in Environment Handling**
   - **Issue**: `sanitize_env_file` used `while IFS= read -r line` without `|| [[ -n $line ]]` (silently dropping the final variable in `env.custom` when no trailing newline was present), did not strip `\r` on Windows CRLF (`\r\n`) files, emitted false `[ERROR] Security: Invalid environment variable blocked` messages on whitespace-only lines (`"    "`), and in `process_environment` (`env -0`), short-circuiting `[[ $entry != *$'\n'* && $entry != *$'\r'* ]] && printf '%s\n' "$entry"` caused the `while` loop to exit `1` whenever the final entry emitted by `env -0` was multiline (e.g., multiline `inputs_additional_apps` or `inputs_custom_docker_commands`).
   - **Fix**: Added `_sanitize_env_stream` with `local LC_ALL=C`, `while IFS= read -r line || [[ -n $line ]]`, `\r` stripping, whitespace-only skipping, and `printf '%s\n' "$line" || return 1` write-error propagation; chained `env.host` + `env.custom` sanitization streams with `&&`; and replaced the `env -0` short-circuit `&&` with `if [[ ... ]]; then printf '%s\n' "$entry" || exit 1; fi`.

---

### Security Fixes

1. **Locale- & `IFS`-Independent Validation (`local LC_ALL=C` / `local IFS`)**
   - **Issue**: Under UTF-8 dictionary collation locales such as `en_US.UTF-8` on standard Linux runners, POSIX ERE character ranges `[a-z]` and `[A-Za-z]` in `[[ ... =~ ... ]]` match uppercase letters (`A`–`Y` fall inside `[a-z]`, allowing `inputs_platform="LINUX/AMD64"`) as well as non-ASCII accented characters (`cürl`, `ÉVIL=1`), while `validate_docker_commands` and `parse_app_list` relied on caller `IFS` when sourced.
   - **Fix**: Scoped `local LC_ALL=C` inside all validation, command-parsing, `WORKDIR`, and OS-detection functions, and scoped `local IFS=$' \t\n'` inside `validate_docker_commands` and `parse_app_list`, enforcing deterministic ASCII matching and whitespace splitting without mutating caller `LC_ALL` or `IFS` when sourced.

2. **Per-Flag Value Validation in `parse_docker_commands` (Closing `-e`/`--env` Blocklist Bypass, Rootfs Mounts & Flag Smuggling)**
   - **Issue**: `parse_docker_commands` previously validated only the leading flag token and `$` / `` ` `` characters, allowing:
     - Blocked loader/shell/runner variables via `--env LD_PRELOAD=/evil.so`, `-e BASH_ENV=/evil.sh`, `-e PATH=/evil`, or `-e GITHUB_ENV=/evil` (bypassing `check_env_var`).
     - Valueless `-e SECRET_VAR` flags, which instruct `docker run` to inherit host runner environment variables into the container even when `inputs_use_host_env=false`.
     - Docker daemon socket mounts (`--volume /var/run/docker.sock:/var/run/docker.sock` or `/var/run/docker.sock/:/s`), host root-filesystem bind mounts (`--volume /:/host`, `--volume /.:/host`, `--volume /./:/host`), container-root mounts (`--volume /tmp:/:ro`), relative container destinations (`--volume /tmp:rel`), `..` path traversal, or extra flags smuggled on a single line (`--volume /tmp:/tmp --privileged`).
     - Silent fail-open skipping if a non-empty line failed to match the option regex.
   - **Fix**: Enforced fail-closed matching and validated every expanded flag value via `validate_input`:
     - `-e` / `--env`: `env_var` (`check_env_var` format, character, and blocklist enforcement).
     - `-v` / `--volume`: `docker_volume` (requires `src:/abs_dst[:opts]` or `/abs_anon`, blocks whitespace, leading `-`, host or container rootfs `^(/+\.?)+(:|$)` / `:(/+\.?)+(:|$)`, `..` traversal segments, and `docker.sock` mounts with or without trailing `/`).
     - `-u` / `--user`: `docker_user` (`uid[:gid]` / `user[:group]`).
     - `-w` / `--workdir`: `docker_workdir` (absolute container path without `..` segments).
     - `--memory`: `docker_memory` (`^[1-9][0-9]*[bBkKmMgG]?$`).
     - `--cpus`: `docker_cpus` (positive integer or decimal CPU limit).

3. **Multiline Environment Injection Fix, Extended Loader/Shell Blocklist & Comprehensive Secret Redaction**
   - **Issue**:
     - In Bash regex matching (`[[ $input =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]`), `.` matches `\n`, allowing multiline strings such as `$'SAFE=1\nLD_PRELOAD=/evil.so'` or `$'SAFE=1\nPATH=/evil'` to pass `check_env_var`, `to_gh_env`, and `to_gh_output`.
     - Blocked environment variable diagnostics (including `-e` / `--env` values containing `$` or `` ` `` and inline `--env=KEY=VAL` / `KEY=VAL` tokens in `inputs_custom_docker_commands`), `_inputs_info` (`GITHUB_STEP_SUMMARY` and stdout), and `docker run` failure logs exposed plaintext `KEY=VALUE` secrets.
   - **Fix**:
     - Explicitly rejected `\n` and `\r` in `check_env_var` and extended the blocklist with `SHELLOPTS`, `BASHOPTS`, `GLIBC_TUNABLES`, `GCONV_PATH`, and `GITHUB_STATE`.
     - Added `redact_env_var`, `format_clean_envs_for_log`, and `=*` value redaction on blocked `docker_arg` / malformed command lines so blocked-env logs, `$` / `` ` `` expansion checks, inline `--env=SECRET=val` mistakes, step summaries (`_inputs_info`), and both fast-path and standard-path `docker run` error messages never expose secret values.

4. **Workspace & Runner File Validation, Build-Context Secret Isolation & `0600` Env Permissions**
   - **Issue**:
     - Fast-path `[[ -f "$workspace/$inputs_dockerfile" ]]` and `cp` followed symbolic links (both leaf symlinks and symlinked subdirectories) and emitted the copied file to stdout and `$GITHUB_STEP_SUMMARY` before `docker build`, allowing a repository symlink to disclose arbitrary host files.
     - `${workspace}/env.custom` also followed symlinks (or silently ignored non-regular directories/FIFOs); pre-existing symlinks, directories, FIFOs, missing parent directories, or unwritable targets on `GITHUB_ENV`, `GITHUB_OUTPUT`, and `GITHUB_STEP_SUMMARY` were not guarded upfront (risking symlink clobbering, FIFO deadlocks, or post-`docker run` failures leaving orphaned containers); and `env.host` / `env.load` were created with default world-readable permissions before `docker build` ran (exposing raw host secrets in the `"$workspace"` Docker build context if a custom Dockerfile ran `COPY .` and leaving `env.host` on disk if `docker build` failed).
   - **Fix**:
     - Added `validate_workspace_file` (using pure-Bash parent resolution and `cd -P` / `pwd -P`) to reject symbolic links along any path component, check readability (`-r`), and verify physical containment within `$workspace`.
     - Added `validate_environment_paths` and `validate_gh_file_target` upfront before building or starting containers, rejecting symlinks, directories, FIFOs (`-p`), other non-regular files, unreadable/non-regular `env.custom`, missing parent directories, and unwritable targets (while preserving `/dev/null` compatibility).
     - Evaluated fast-path `-s`, `extract_dockerfile_workdir`, and post-`WORKDIR` `parse_docker_commands` *before* copying to `"$dockerfile_path"` (avoiding leaked temporary Dockerfiles on validation exit), checked `[[ -L $dockerfile_path ]]` before `-ef` so pre-existing symlinks at `qbt_builder_dockerfile` pointing to `inputs_dockerfile` are replaced and cleaned up without deleting the source file, deferred `process_environment` until after `docker build` succeeds, eliminated intermediate `.safe` disk files, and wrote `env.host` and `env.load` under `umask 077` (`0600`).

5. **CLI Flag Injection, Non-Root Absolute Workspace Enforcement & `WORKDIR` Traversal Prevention**
   - **Issue**:
     - `validate_input` (`package_name`) allowed leading hyphens (`--allow-untrusted`, `-o ...`) interpolated into `apk add` and `apt-get install`.
     - `inputs_os_id`, arch-prefixed `image_name`, and `inputs_os_version_id` allowed leading hyphens (`-f`), leading/trailing `/`, `//`, or `..` segments, and `docker buildx imagetools inspect` passed `"$image"` without `--`.
     - Relative `GITHUB_WORKSPACE` values (e.g., `relative_dir`) caused `docker run -v "$workspace:$wd"` to mount an empty named Docker volume instead of bind-mounting the workspace, `GITHUB_WORKSPACE=/` (or `/.`) bind-mounted the host root filesystem `/` into the container, and fast-path `extracted_wd` previously permitted `..` traversal paths.
   - **Fix**:
     - Required leading ASCII alphanumeric `[a-zA-Z0-9]` on `package_name`, valid OCI repository syntax on `inputs_os_id` / `image_name`, and leading `[a-zA-Z0-9_]` on `inputs_os_version_id`; passed `--` before `"$image"` in `docker buildx imagetools inspect`.
     - Enforced that `$workspace` is an existing non-root absolute directory (`/*`, resolving via `cd -P` / `pwd -P` to a path other than `/`) containing no `:`, `\n`, or `\r`.
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
     - Guarded `GITHUB_ENV`, `GITHUB_OUTPUT`, and `GITHUB_STEP_SUMMARY` writes when unset, replaced all `tee -a` pipelines on runner files with `&&`-chained checked `>>` appends, checked `generate_*_dockerfile > "$dockerfile_path"` directly alongside `-s` verification, read `"$dockerfile_path"` via Bash `$(< ...)` with `printf '%s\n'` (ensuring Dockerfiles without a trailing newline never corrupt closing ```` ``` ```` fences in `GITHUB_STEP_SUMMARY`), checked exit codes on all `env.load`, `GITHUB_STEP_SUMMARY`, and `_env_info` writes, and cleaned up temporary Dockerfiles on empty-file or build failure.
     - Replaced external `printf | tr`, `cat`, and `dirname` forks with pure-Bash parameter/file expansion, extended case-insensitive remote/URI rejection in fast-path (`ftp://`, `git://`, `ssh://`, `file://`, `HTTPS://`), and aligned top-of-file comments with actual script behavior.

3. **Validated Baseline Hardening Retained**
   - Preserved `RUNNER_ARCH` and arch-prefixed image platform auto-detection with explicit `inputs_platform` precedence, single `--platform` flag emission, `--cap-drop ALL` with minimal capability grants (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`), `-u 1001:1001` non-root container execution when `inputs_use_root=false`, safe `$wd` / `${wd}` boundary expansion in `parse_docker_commands`, stale `env.load` cleanup, and `env -0` NUL-delimited host environment capture.

---

### Unit Test Suite (`actions/qbt_docker/test_action_bash.bash`)

- **Fixed Masked, Coupled & Vacuous Assertions**:
  - Updated `OS Detection via Buildx Metadata (jq)` tests to use OS-neutral image names (`ghcr.io/userdocs/qbt-nox`, `ghcr.io/userdocs/qbt-custom`, `custom/myimage`) instead of `qbt-debian`, `qbt-ubuntu`, and `mydebian`, which previously allowed `detect_os_fallback` name parsing to mask broken `jq` metadata queries.
  - Hardened `assert_not_dockerfile` and `assert_dockerfile` to verify `${tmp_dir}/last_dockerfile` exists before grepping, added `--` option terminators across `grep` helpers, ensured build-context assertions invoke their own setup explicitly, and verified command exit codes / `docker run` execution in negative assertions (`PATH=`, `LD_PRELOAD=`, `env.host` ignored, `inputs_use_root=true`).
- **Expanded Coverage (96 -> 199 Assertions Passing)**:
  - **Locale, `IFS` & Input Validation**: UTF-8 locale collation regression tests (`LINUX/AMD64` and non-ASCII `cürl` under UTF-8 locale, plus caller `LC_ALL` and custom `IFS` preservation when sourced), leading-hyphen flag injection on `inputs_os_id`, arch-prefixed `inputs_os_id`, `inputs_os_version_id`, and `inputs_additional_apps` (`--allow-untrusted`), `..` segment rejection on `inputs_os_id`, colon, relative, and root (`/` and `/.`) workspace rejection, `i386/alpine -> linux/i386`, valid `+`/`.`/`-` package names, symlink/directory/FIFO/missing-parent rejection on `GITHUB_ENV` / `GITHUB_OUTPUT` / `GITHUB_STEP_SUMMARY`, and `/dev/null` target support.
  - **Fast-Path Dockerfile & `WORKDIR`**: `file://` and uppercase `HTTPS://` URI rejection, trailing-slash (`my.Dockerfile/`) and bare `.` rejection, consecutive-dot filenames (`my..Dockerfile`), `-ef` preservation when `inputs_dockerfile="qbt_builder_dockerfile"` and replacement of pre-existing symlinks at `qbt_builder_dockerfile -> real.Dockerfile`, non-creation of temp `qbt_builder_dockerfile` when post-`WORKDIR` custom command validation fails, symlinked `inputs_dockerfile` and symlinked parent directory rejection with non-disclosure verification, standalone `validate_workspace_file` `..` and trailing-slash rejection, empty Dockerfile cleanup, path-traversing `WORKDIR`, sequential relative `WORKDIR`, `.` / `/./` segment normalization (`WORKDIR /opt/./app` + `WORKDIR .`), multi-stage `WORKDIR` isolation and `FROM <alias>` inheritance, multiline `FROM \` + BuildKit `RUN <<HEREDOC`, piped `RUN cat <<EOF | sh`, and relative-destination `COPY <<EOF entrypoint.sh`, `<<<` here-string / `<<` bitshift non-interference, dangling trailing `\` at EOF (including intact closing ```` ``` ```` code fences in `GITHUB_STEP_SUMMARY` without trailing newline), bracket/command `FROM` subscript-injection safety, and `$workspace` build context verification.
  - **OS Detection & Dockerfile Generation**: Target `$inputs_platform` manifest selection and `linux/arm64` <-> `linux/arm64/v8` OCI variant mapping on multi-arch Buildx JSON, `alpine/git` and `ubuntu/squid` org-prefixed image detection, `docker.io/library/debian:bookworm` and `@sha256` digest `.name` detection, port-qualified `registry:5000/...` + `@sha256` userdocs `base.name` detection, multi-arch Buildx JSON skipping leading empty attestation entries, `DEBIAN_FRONTEND` and `ALPINE_MIRROR` history false-positive immunity (word-bounded token extraction), and unknown-OS fallback command grouping and `bash` installation.
  - **Environment & Custom Docker Flags**: CRLF + missing trailing newline and whitespace-only lines in `env.custom`, `inputs_use_host_env=true` resilience when the trailing `env -0` variable is multiline, `env.load` and `env.custom` directory collision rejection, extended loader/shell/`GITHUB_STATE` blocklist, secret value redaction across blocked-env logs, `$` expansion errors on `--env`, inline `--env=KEY=VAL` errors, step summaries (`_inputs_info`), and `docker run` error logs, symlinked `env.custom` rejection, `env.host` symlink clobber protection + `0600` file mode verification, non-creation of `env.host` on failed validation or failed fast-path/standard `docker build`, blocked `--env LD_PRELOAD`, `-e PATH`, valueless `-e HOME`, `docker.sock` and `docker.sock/` mounts, host rootfs (`/:/host`, `/.:/host`, `/./:/host`), container rootfs (`/tmp:/:ro`), and relative container destination mounts, allowed hidden dot-directory mounts (`/tmp/.cache:/app/.cache:ro`), smuggled extra flags (`--volume /tmp:/tmp --privileged`), `--workdir` traversal, zero `--memory`/`--cpus`, and valid `-u`/`-w`/`:ro`/decimal `--cpus`.
  - **Sourcing & Execution Resilience**: Multiline `to_gh_env` / `to_gh_output` rejection, idempotent double-sourcing under `set -e` with stderr capture, execution with unset `GITHUB_*` file variables, and missing `docker` binary handling.
  - Static validation passing with zero warnings/diffs under `bash -n`, `shellcheck -s bash`, and `shfmt -d -s -bn -ci -sr -i 0`.
