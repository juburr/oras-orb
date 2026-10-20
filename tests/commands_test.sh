#!/usr/bin/env bash
#
# Tests src/scripts/push.sh, pull.sh, attach.sh and logout.sh against a
# stand-in oras that records its arguments and working directory, and writes
# a fixed manifest wherever --export-manifest points:
#
#   - each command builds exactly the oras arguments expected, with no empty
#     argument where an optional array is empty, even on bash < 4.4
#   - files and extra_args split like shell words: quotes keep spaces, and a
#     $(...) or backtick reaches nothing that runs it
#   - annotations take one key=value per line, so values keep commas and
#     spaces, and a line without a key and = stops the step before oras runs
#   - push and attach run oras in working_dir and export the digest of the
#     manifest oras wrote, shell-quoted, to the variable digest_env_var names
#   - a failed oras, or one that wrote no manifest, fails the step and
#     exports nothing
#   - missing required values stop the step before oras runs
#   - nothing is left in TMPDIR
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it. The circleci CLI is stubbed when it isn't on the PATH.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"
SCRIPT_ORAS_LIB=$(cat "${SCRIPTS}/lib/oras.sh")
export SCRIPT_ORAS_LIB

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/tmp" "${WORK}/job/out dir"

# A stand-in for the circleci CLI, which only has to substitute nothing.
if ! command -v circleci > /dev/null 2>&1; then
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/circleci"
    chmod +x "${WORK}/bin/circleci"
fi

# The manifest the stand-in oras writes for --export-manifest, and its digest.
MANIFEST_JSON='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}'
MANIFEST_DIGEST="sha256:$(printf '%s' "${MANIFEST_JSON}" | sha256sum | awk '{ print $1 }')"

# Records oras's arguments, one per line, and its working directory, and
# writes the manifest unless ORAS_NO_MANIFEST is set.
cat > "${WORK}/bin/oras" << EOF
#!/bin/bash
printf '%s\n' "\$@" > "${WORK}/oras-args"
pwd > "${WORK}/oras-cwd"
previous=""
for arg in "\$@"; do
    if [[ "\${previous}" == "--export-manifest" && -z "\${ORAS_NO_MANIFEST:-}" ]]; then
        printf '%s' '${MANIFEST_JSON}' > "\${arg}"
    fi
    previous=\${arg}
done
exit "\${ORAS_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/oras"

FAILURES=0
RC=0
OUTPUT=""

# run SCRIPT [VAR=value ...]: runs SCRIPT from the job directory with its
# parameters' defaults, overridden by the given assignments, and sets RC and
# OUTPUT. BASH_ENV starts empty.
run() {
    local script=$1
    shift
    rm -f "${WORK}/oras-args" "${WORK}/oras-cwd"
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${WORK}/job" && env \
        PATH="${WORK}/bin:${PATH}" \
        TMPDIR="${WORK}/tmp" \
        BASH_ENV="${WORK}/bash_env" \
        "${DEFAULTS[@]}" \
        "$@" \
        bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        if [[ -f "${WORK}/oras-args" ]]; then
            printf '    oras args:\n'
            printf '    | %s\n' "$(cat "${WORK}/oras-args")"
        fi
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
oras_not_run() { [[ ! -e "${WORK}/oras-args" ]]; }
tmp_is_empty() { [[ -z "$(ls -A "${WORK}/tmp")" ]]; }
cwd_is() { [[ "$(cat "${WORK}/oras-cwd")" == "$1" ]]; }
nothing_exported() { [[ ! -s "${WORK}/bash_env" ]]; }
# args_are ARG...: oras got exactly these arguments. The manifest path, a
# temporary file, matches the word MANIFEST.
args_are() {
    [[ -f "${WORK}/oras-args" ]] || return 1
    local got
    got=$(awk -v tmp="${WORK}/tmp/" 'previous == "--export-manifest" && index($0, tmp) == 1 { $0 = "MANIFEST" } { print; previous = $0 }' "${WORK}/oras-args")
    [[ "${got}" == "$(printf '%s\n' "$@")" ]]
}
# exported NAME VALUE: a clean shell that sources BASH_ENV sees NAME=VALUE.
exported() {
    # shellcheck disable=SC2016 # expanded by the clean shell, not here
    [[ "$(env -i bash -c 'source "$1"; printf "%s" "${!2}"' _ "${WORK}/bash_env" "$1")" == "$2" ]]
}

# --- push
DEFAULTS=(PARAM_REFERENCE="registry.example/myorg/reports:1.0.0" PARAM_FILES="report.txt"
    PARAM_ARTIFACT_TYPE="" PARAM_ANNOTATIONS="" PARAM_WORKING_DIR="." PARAM_PLAIN_HTTP="0"
    PARAM_EXTRA_ARGS="" PARAM_DIGEST_ENV_VAR="ORAS_PUSHED_DIGEST")

run push.sh
check "push succeeds" rc_is_zero
check "push passes no optional flags by default" \
    args_are push --export-manifest MANIFEST "registry.example/myorg/reports:1.0.0" report.txt
check "push runs oras in the working directory" cwd_is "${WORK}/job"
check "push exports the manifest digest" exported ORAS_PUSHED_DIGEST "${MANIFEST_DIGEST}"
check "push removes the exported manifest" tmp_is_empty

run push.sh PARAM_ARTIFACT_TYPE="application/vnd.example.report.v1" PARAM_PLAIN_HTTP="1" \
    PARAM_FILES=$'report.txt "two words.txt"\n\'sbom file.json:application/spdx+json\'' \
    PARAM_ANNOTATIONS=$'org.opencontainers.image.description=Nightly, full scan\n\n  com.example.id=a=b  ' \
    PARAM_EXTRA_ARGS='--concurrency 10 --header "X-Note: two words"' \
    PARAM_DIGEST_ENV_VAR="REPORT_DIGEST"
check "push with every option succeeds" rc_is_zero
check "push passes each option, file and annotation as its own argument" \
    args_are push --export-manifest MANIFEST --artifact-type application/vnd.example.report.v1 --plain-http \
    --annotation "org.opencontainers.image.description=Nightly, full scan" --annotation "com.example.id=a=b" \
    --concurrency 10 --header "X-Note: two words" \
    "registry.example/myorg/reports:1.0.0" report.txt "two words.txt" "sbom file.json:application/spdx+json"
check "push exports to the variable digest_env_var names" exported REPORT_DIGEST "${MANIFEST_DIGEST}"

run push.sh PARAM_WORKING_DIR="out dir"
check "push runs oras in working_dir" cwd_is "${WORK}/job/out dir"

run push.sh PARAM_WORKING_DIR="missing"
check "push rejects a working_dir that doesn't exist" rc_is_nonzero
check "push does not run oras without its working_dir" oras_not_run

# shellcheck disable=SC2016 # the command substitution must reach the script unexpanded
run push.sh PARAM_EXTRA_ARGS='--concurrency $(touch pwned)'
check "push refuses a command substitution in extra_args" rc_is_nonzero
check "push explains the command substitution" output_has "ERROR: extra_args could not be split into arguments"
check "push runs nothing from extra_args" test ! -e "${WORK}/job/pwned"
check "push does not run oras with unusable extra_args" oras_not_run

run push.sh PARAM_FILES='"unclosed.txt'
check "push refuses files with a quote that is never closed" rc_is_nonzero
check "push names files in the quoting error" output_has "ERROR: files could not be split into arguments"

run push.sh PARAM_ANNOTATIONS=$'good=1\nno equals sign'
check "push refuses an annotation without key=value" rc_is_nonzero
check "push names the bad annotation" output_has "ERROR: Each line of annotations must be key=value, got 'no equals sign'"
check "push does not run oras with a bad annotation" oras_not_run

run push.sh PARAM_ANNOTATIONS="=no key"
check "push refuses an annotation without a key" rc_is_nonzero

run push.sh PARAM_FILES=" "
check "push requires files" rc_is_nonzero
check "push says files is required" output_has "ERROR: files is required"

run push.sh PARAM_REFERENCE=""
check "push requires a reference" rc_is_nonzero
check "push says reference is required" output_has "ERROR: reference is required"

run push.sh PARAM_DIGEST_ENV_VAR="1BAD"
check "push refuses a digest_env_var that can't name a variable" rc_is_nonzero

run push.sh ORAS_EXIT=1
check "push fails when oras push fails" rc_is_nonzero
check "push exports nothing when oras fails" nothing_exported
check "push removes the manifest file when oras fails" tmp_is_empty

run push.sh ORAS_NO_MANIFEST=1
check "push fails when oras writes no manifest" rc_is_nonzero
check "push says the digest is unknown" output_has "ERROR: oras did not write the manifest it pushed"
check "push exports nothing without a manifest" nothing_exported

run push.sh BASH_ENV=""
check "push succeeds without BASH_ENV" rc_is_zero
check "push warns that nothing was exported" output_has "WARN: BASH_ENV is not set"

# --- attach
DEFAULTS=(PARAM_SUBJECT="registry.example/myorg/app@${MANIFEST_DIGEST}"
    PARAM_ARTIFACT_TYPE="application/spdx+json" PARAM_FILES="sbom.json" PARAM_ANNOTATIONS=""
    PARAM_WORKING_DIR="." PARAM_PLAIN_HTTP="0" PARAM_EXTRA_ARGS="" PARAM_DIGEST_ENV_VAR="ORAS_ATTACHED_DIGEST")

run attach.sh
check "attach succeeds" rc_is_zero
check "attach passes only the artifact type and manifest flags by default" \
    args_are attach --artifact-type application/spdx+json --export-manifest MANIFEST \
    "registry.example/myorg/app@${MANIFEST_DIGEST}" sbom.json
check "attach exports the manifest digest" exported ORAS_ATTACHED_DIGEST "${MANIFEST_DIGEST}"
check "attach removes the exported manifest" tmp_is_empty

run attach.sh PARAM_FILES="" PARAM_ANNOTATIONS="com.example.reviewed=true" PARAM_PLAIN_HTTP="1"
check "attach accepts annotations without files" rc_is_zero
check "attach passes no file argument without files" \
    args_are attach --artifact-type application/spdx+json --export-manifest MANIFEST --plain-http \
    --annotation com.example.reviewed=true "registry.example/myorg/app@${MANIFEST_DIGEST}"

run attach.sh PARAM_FILES="" PARAM_ANNOTATIONS=""
check "attach requires files or annotations" rc_is_nonzero
check "attach says what it needs" output_has "ERROR: attach needs files, annotations or both"

run attach.sh PARAM_ARTIFACT_TYPE=""
check "attach requires an artifact type" rc_is_nonzero
check "attach does not run oras without an artifact type" oras_not_run

run attach.sh PARAM_SUBJECT=""
check "attach requires a subject" rc_is_nonzero
check "attach says subject is required" output_has "ERROR: subject is required"

run attach.sh ORAS_EXIT=1
check "attach fails when oras attach fails" rc_is_nonzero
check "attach exports nothing when oras fails" nothing_exported

# --- pull
DEFAULTS=(PARAM_REFERENCE="registry.example/myorg/reports:1.0.0" PARAM_OUTPUT_DIR="."
    PARAM_PLAIN_HTTP="0" PARAM_EXTRA_ARGS="")

run pull.sh
check "pull succeeds" rc_is_zero
check "pull passes no optional flags by default" \
    args_are pull --output . "registry.example/myorg/reports:1.0.0"

run pull.sh PARAM_OUTPUT_DIR="pulled/new dir" PARAM_PLAIN_HTTP="1" PARAM_EXTRA_ARGS="--keep-old-files"
check "pull with every option succeeds" rc_is_zero
check "pull passes each option" \
    args_are pull --output "pulled/new dir" --plain-http --keep-old-files "registry.example/myorg/reports:1.0.0"
check "pull creates output_dir" test -d "${WORK}/job/pulled/new dir"

run pull.sh PARAM_REFERENCE=""
check "pull requires a reference" rc_is_nonzero
check "pull does not run oras without a reference" oras_not_run

run pull.sh ORAS_EXIT=1
check "pull fails when oras pull fails" rc_is_nonzero

# --- logout
DEFAULTS=(PARAM_REGISTRY="registry.example:5000")

run logout.sh
check "logout succeeds" rc_is_zero
check "logout runs oras logout for the registry" args_are logout "registry.example:5000"

run logout.sh PARAM_REGISTRY=""
check "logout requires a registry" rc_is_nonzero
check "logout does not run oras without a registry" oras_not_run

run logout.sh ORAS_EXIT=1
check "logout fails when oras logout fails" rc_is_nonzero

# --- oras_export
# The digests above need no quoting, so the helper gets a value that does.
# shellcheck disable=SC2016 # the command substitution must reach oras_export unexpanded
HOSTILE='two words $(touch '"${WORK}"'/job/exported-pwned) "quoted"'
: > "${WORK}/bash_env"
OUTPUT=$(BASH_ENV="${WORK}/bash_env" bash -c 'set -euo pipefail; eval "$1"; oras_export HOSTILE_VALUE "$2"' _ \
    "${SCRIPT_ORAS_LIB}" "${HOSTILE}" 2>&1)
RC=$?
check "oras_export writes the value" rc_is_zero
check "oras_export shell-quotes the value" exported HOSTILE_VALUE "${HOSTILE}"
check "oras_export runs nothing in the value" test ! -e "${WORK}/job/exported-pwned"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All push, pull, attach and logout tests passed."
