# Changelog – `actions/qbt_docker`

## Security, Correctness & Reliability Audit (2026-11-27)

Consolidated audit of `actions/qbt_docker/action.bash` and `actions/qbt_docker/test_action_bash.bash`.

---

### Security Fixes

1. **Deterministic Locale & `IFS` Scoping**
   - Scoped `local LC_ALL=C` in all validation, command-parsing, environment-stream, `WORKDIR`, and OS-detection functions so POSIX character ranges (`[a-z]`, `[A-Za-z0-9]`) never match uppercase or non-ASCII characters under UTF-8 collation locales (`en_US.UTF-8`), without mutating caller `LC_ALL` when sourced.
   - Scoped `local IFS` in whitespace-splitting and `"${array[*]}"`-joining functions so custom caller `IFS` values cannot break tokenization or package/flag joining when sourced.

2. **Custom Docker Flag Value Validation (`parse_docker_commands` / `validate_input`)**
   - Closed fail-open line skipping and validated every expanded flag value by flag type:
     - `-e` / `--env`: enforced `check_env_var` (closing `LD_PRELOAD`, `BASH_ENV`, `PATH`, `GITHUB_*` blocklist bypasses and valueless `-e VAR` host-env inheritance).
     - `-v` / `--volume`: required `src:/abs_dst[:opts]` or `/abs_anon`, blocking `docker.sock` mounts, host/container root-filesystem mounts (`/:/host`, `/.:/host`, `/tmp:/:ro`), relative container destinations, `..` traversal, and extra flags smuggled on a single line.
     - `-u` / `--user`, `-w` / `--workdir`, `--memory`, `--cpus`: validated user/group syntax, non-traversing absolute workdirs, and positive memory/CPU specifications.

3. **Environment Injection Prevention & Secret Redaction**
   - Rejected embedded `\n` and `\r` in `check_env_var` (preventing multiline injection in `to_gh_env`, `to_gh_output`, and `--env`) and extended the blocklist with `SHELLOPTS`, `BASHOPTS`, `GLIBC_TUNABLES`, `GCONV_PATH`, and `GITHUB_STATE`.
   - Added `redact_env_var`, `format_clean_envs_for_log`, and `=*` value redaction on blocked arguments so secret values are never logged in blocked-env diagnostics, step summaries (`_inputs_info`), or `docker run` error messages.

4. **Workspace, Symlink, Runner Target & Build-Context Isolation**
   - Required `$workspace` to be an existing non-root absolute path (`/*`, not `/`) without `:` or newlines.
   - Added `validate_workspace_file` to reject symlinks, `..` traversal, bare `.`, trailing slashes, and unreadable files on `inputs_dockerfile` before reading or copying.
   - Validated `GITHUB_ENV`, `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, and `env.custom`/`env.load`/`env.host` upfront against symlinks, directories, FIFOs, non-regular files, and unwritable paths (preserving `/dev/null`).
   - Moved `process_environment` after `docker build` and wrote `env.host` / `env.load` under `umask 077` (`0600`) without `.safe` intermediate files so host/custom secrets are never exposed in the `"$workspace"` build context or left behind on build failure.

5. **CLI Flag Injection Protection**
   - Required leading alphanumeric characters on `package_name` (blocking `--allow-untrusted` / `-o` injection into `apk`/`apt-get`), valid OCI name/tag formats on `inputs_os_id` and `inputs_os_version_id`, and `--` before `"$image"` in `docker buildx imagetools inspect`.

---

### Bug & Regression Fixes

1. **Idempotent Sourcing (`readonly` Constants)**
   - Moved `readonly` locking of `container_name`, `non_root_user`, `non_root_uid`, `non_root_gid`, and `workspace` inside the `if [[ ${BASH_SOURCE[0]} == "${0}" ]]` guard so direct execution stays immutable while re-sourcing in the same shell succeeds cleanly.

2. **Dockerfile Path Validation (`my..Dockerfile`)**
   - Replaced `\.\.` substring matching in `dockerfile_path` validation with `..` path-segment matching (`(^|/)\.\.(/|$)`), allowing valid filenames containing consecutive dots while rejecting `..`, `.`, leading/trailing `/`, `//`, and leading `-`.

3. **OS Detection Accuracy (`detect_os_*`)**
   - Added `_jq_image_selector` with `--arg plat "${inputs_platform:-}"` to prefer the target platform manifest (including `linux/arm64` <-> `linux/arm64/v8`) and skip empty attestation entries in multi-arch Buildx JSON.
   - Fixed `docker.io/library/...` and org-namespace (`alpine/git`, `ubuntu/squid`) handling in `detect_os_official` and `detect_os_fallback`, fixed `registry:port/...` and `@sha256` digest parsing in `detect_os_userdocs`, normalized case across all detection stages, and extracted word-bounded OS tokens in `detect_os_fallback_with_metadata` so `ENV DEBIAN_FRONTEND=noninteractive` or `ALPINE_MIRROR=...` cannot misclassify images.

4. **Stage-Aware Fast-Path `WORKDIR` Resolution (`extract_dockerfile_workdir`)**
   - Replaced whole-file `grep | tail -1 | sed` with `extract_dockerfile_workdir` in pure Bash to track `FROM` stage boundaries and `FROM <alias>` inheritance, join `\` continuations, skip BuildKit `<<EOF` / `<<-EOF` heredoc bodies, resolve sequential relative `WORKDIR` instructions, normalize `//` and `/./` / `/.` segments, and re-validate `$wd`-expanded custom Docker commands before creating temporary files.

5. **Environment Stream & Standard Fallback Dockerfile Reliability**
   - Fixed `sanitize_env_file` / `_sanitize_env_stream` to preserve final lines without trailing newlines, strip `\r` on CRLF files, skip whitespace-only lines without false errors, and propagate write failures; fixed `env -0` host dumping so trailing multiline variables do not cause non-zero loop exit codes.
   - Fixed operator precedence (`{ groupadd ... || addgroup ... || true; }`), installed `bash` alongside `sudo` on `apk` fallback images, aligned `useradd -d ${wd}`, and ensured `/etc/sudoers.d` exists in `generate_standard_dockerfile`.
   - Passed `"$workspace"` as the `docker build` context in both paths, guarded unset `GITHUB_*` file variables, replaced `tee` pipelines with checked writes and `_log_dockerfile` / `_emit_outputs` helpers, handled `qbt_builder_dockerfile` `-ef`/symlink edge cases, and verified `command -v docker` upfront.

---

### Unit Test Suite (`actions/qbt_docker/test_action_bash.bash`)

- Replaced OS-hinting test image names (`qbt-debian`, `qbt-ubuntu`, `mydebian`) with OS-neutral names in Buildx `jq` metadata tests so fallback name parsing cannot mask broken `jq` queries.
- Enforced `last_rc -eq 0` across `assert_gh_output`, `assert_docker`, `assert_dockerfile`, and `assert_not_dockerfile`, and `exit 1` in `assert_fail_output`.
- Expanded valid, non-vacuous coverage from 96 to **200 assertions** covering input/locale/`IFS` validation, custom Docker flag security and secret redaction, symlink/path/workspace/runner-target protections, multi-arch Buildx OS detection, environment sanitization, multi-stage/relative `WORKDIR` resolution, build/run error handling, and sourcing resilience.
