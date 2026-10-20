#!/usr/bin/env bash
#
# Tests src/scripts/login.sh against a stand-in oras that records its
# arguments and stdin:
#
#   - the password reaches oras on stdin (--password-stdin), never in its
#     arguments, and is never printed
#   - xtrace that a job turns on for every step (SHELLOPTS, or set -x in
#     $BASH_ENV) is off before the credentials are read
#   - a password of -n reaches oras intact (echo would take it as an option)
#   - an empty username leaves --username out, so ORAS takes the password as
#     an identity token, while an empty password stops the step before oras
#     runs
#   - a registry given as a URL or with a repository path is refused
#   - without plain_http, oras gets no extra flags, even on bash < 4.4
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
SCRIPT="${ROOT}/src/scripts/login.sh"
SCRIPT_ORAS_LIB=$(cat "${ROOT}/src/scripts/lib/oras.sh")
export SCRIPT_ORAS_LIB

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/no-oras"

# A stand-in for the circleci CLI, which only has to substitute nothing.
if ! command -v circleci > /dev/null 2>&1; then
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/circleci"
    chmod +x "${WORK}/bin/circleci"
    cp "${WORK}/bin/circleci" "${WORK}/no-oras/circleci"
fi

# Records oras's arguments, one per line, and its stdin.
cat > "${WORK}/bin/oras" << EOF
#!/bin/bash
printf '%s\n' "\$@" > "${WORK}/oras-args"
cat > "${WORK}/oras-stdin"
exit "\${ORAS_EXIT:-0}"
EOF
chmod +x "${WORK}/bin/oras"

TEST_USERNAME="ci-user"
# shellcheck disable=SC2016 # the $ is part of the password, not an expansion
TEST_PASSWORD='s3cret "quoted" $HOME value'

FAILURES=0
RC=0
OUTPUT=""

# run_login [VAR=value ...]: runs login.sh with default parameters,
# overridden by the given assignments, and sets RC and OUTPUT.
run_login() {
    rm -f "${WORK}/oras-args" "${WORK}/oras-stdin"
    OUTPUT=$(env -u BASH_ENV \
        PATH="${WORK}/bin:${PATH}" \
        REGISTRY_USERNAME="${TEST_USERNAME}" \
        REGISTRY_PASSWORD="${TEST_PASSWORD}" \
        PARAM_USERNAME="REGISTRY_USERNAME" \
        PARAM_PASSWORD="REGISTRY_PASSWORD" \
        PARAM_REGISTRY="registry.example:5000" \
        PARAM_PLAIN_HTTP="0" \
        "$@" \
        bash "${SCRIPT}" 2>&1)
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
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
oras_not_run() { [[ ! -e "${WORK}/oras-args" ]]; }
args_lack() { ! grep -qF -- "$1" "${WORK}/oras-args"; }
stdin_is() { [[ -f "${WORK}/oras-stdin" && "$(cat "${WORK}/oras-stdin")" == "$1" ]]; }
args_are() { [[ -f "${WORK}/oras-args" && "$(cat "${WORK}/oras-args")" == "$(printf '%s\n' "$@")" ]]; }

# Without plain_http and with a username, LOGIN_ARGS has no optional flags.
# The exact arguments also rule out an empty one.
run_login
check "logs in" rc_is_zero
check "runs oras login with the username and the password on stdin" \
    args_are login --password-stdin --username "${TEST_USERNAME}" "registry.example:5000"
check "sends the password on stdin" stdin_is "${TEST_PASSWORD}"
check "keeps the password off oras's command line" args_lack "s3cret"
check "never prints the password" output_lacks "s3cret"
check "names the variables the credentials came from" output_has "Password: from REGISTRY_PASSWORD"

run_login PARAM_PLAIN_HTTP="1"
check "passes --plain-http when asked" \
    args_are login --password-stdin --username "${TEST_USERNAME}" --plain-http "registry.example:5000"

run_login PARAM_PLAIN_HTTP="maybe"
check "rejects a plain_http that isn't a boolean" rc_is_nonzero
check "names plain_http in the error" output_has "ERROR: plain_http must be true or false"

# echo would take a password of -n as its own option and send nothing.
run_login REGISTRY_PASSWORD="-n"
check "logs in with a password of -n" rc_is_zero
check "sends a password of -n on stdin" stdin_is "-n"

run_login SHELLOPTS=xtrace
check "logs in with xtrace turned on for the job" rc_is_zero
check "turns xtrace off before reading the credentials" output_lacks "s3cret"

run_login REGISTRY_USERNAME=""
check "logs in with an identity token when the username is empty" rc_is_zero
check "leaves --username out for an identity token" \
    args_are login --password-stdin "registry.example:5000"
check "says the password is used as an identity token" output_has "identity token"

run_login PARAM_PASSWORD="UNSET_TEST_PASSWORD"
check "fails when the password variable is unset" rc_is_nonzero
check "names the empty password variable" output_has "ERROR: The UNSET_TEST_PASSWORD environment variable"
check "does not run oras without a password" oras_not_run

run_login PARAM_PASSWORD="not a name"
check "rejects a password parameter that can't name a variable" rc_is_nonzero
check "names the password parameter in the error" output_has "ERROR: password must name an environment variable"

run_login PARAM_REGISTRY="https://registry.example"
check "rejects a registry given as a URL" rc_is_nonzero
check "does not run oras for a URL" oras_not_run

run_login PARAM_REGISTRY="registry.example/myorg"
check "rejects a registry with a repository path" rc_is_nonzero

run_login PARAM_REGISTRY=""
check "rejects an empty registry" rc_is_nonzero
check "says registry is required" output_has "ERROR: registry is required"

run_login ORAS_EXIT=1
check "fails when oras login fails" rc_is_nonzero

run_login SCRIPT_ORAS_LIB=""
check "fails without the shared helpers" rc_is_nonzero
check "says the shared helpers are missing" output_has "ERROR: The shared helpers were not loaded"

# Without oras on the PATH, unless a real one is installed there.
NO_ORAS_PATH="${WORK}/no-oras:/usr/local/bin:/usr/bin:/bin"
if PATH="${NO_ORAS_PATH}" command -v oras > /dev/null 2>&1; then
    echo "skip: oras is installed, so the missing-oras error was not checked"
else
    run_login PATH="${NO_ORAS_PATH}"
    check "fails when oras is not installed" rc_is_nonzero
    check "says to run the install command" output_has "Run the install command"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All login tests passed."
