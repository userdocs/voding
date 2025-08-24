#!/bin/bash

runner_arch=ARM
guess_the_arch=armv7l

GITHUB_ENV=ghenv.txt
GITHUB_OUTPUT=gheout.txt
GITHUB_STEP_SUMMARY=ghsummary.txt

# Functions for consistent logging
log_info() {
	printf '[INFO] %s\n' "$1"
}

log_error() {
	printf '[ERROR] %s\n' "$1" >&2
}

log_debug() {
	printf '[DEBUG] %s\n' "$1"
}

to_gh_env() {
	printf '%s\n' "${1}" | tee -a "$GITHUB_ENV"
}

to_gh_output() {
	printf '%s\n' "${1}" | tee -a "$GITHUB_OUTPUT"
}

log_summary() {
	printf '%b\n' '```bash' | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' "${1}" | tee -a "$GITHUB_STEP_SUMMARY"
	printf '%b\n' '```' | tee -a "$GITHUB_STEP_SUMMARY"
}

unset skip_qemu

case "${runner_arch}" in
	X86 | X64)
		if [[ ${guess_the_arch} =~ ^(default|amd64|x86*|i386|i586|i686)$ ]]; then
			to_gh_env "skip_qemu=true"
			log_summary skip_qemu=true
		fi
		;;
	ARM | ARM64)
		if [[ ${guess_the_arch} =~ ^(default|aarch64|arm.*)$ ]]; then
			to_gh_env "skip_qemu=true"
			log_summary skip_qemu=true
		fi
		;;
esac

if [[ $skip_qemu == 'true' ]]; then
	to_gh_env "skip_qemu=no"
	to_gh_env "qemu_target=${BASH_REMATCH[0]}"
	log_summary "skip_qemu=no"
	log_summary "qemu_target=${BASH_REMATCH[0]}"
fi
