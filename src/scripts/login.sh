#!/bin/bash
#
# Logs in to a registry for the login command, with oras login. ORAS stores
# the credentials where Docker does (~/.docker/config.json, or the credential
# helper it names), so later oras and docker commands use them too.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the password.
set +o xtrace

if [[ -z "${SCRIPT_ORAS_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_ORAS_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_ORAS_LIB}"

REGISTRY=$(oras_subst "${PARAM_REGISTRY}")
PLAIN_HTTP=$(oras_bool plain_http "${PARAM_PLAIN_HTTP}")
oras_env_var_name username "${PARAM_USERNAME}"
oras_env_var_name password "${PARAM_PASSWORD}"
USERNAME=${!PARAM_USERNAME:-}
PASSWORD=${!PARAM_PASSWORD:-}

# Removes the credentials from this shell when the step ends, whatever its
# outcome.
cleanup_secrets() {
    unset PASSWORD USERNAME
}
trap cleanup_secrets EXIT

if [[ -z "${REGISTRY}" ]]; then
    echo "ERROR: registry is required, such as ghcr.io or localhost:5000." >&2
    exit 1
fi
if [[ "${REGISTRY}" == *://* || "${REGISTRY}" == */* ]]; then
    echo "ERROR: registry must be a host with an optional port, such as ghcr.io or localhost:5000, not '${REGISTRY}'." >&2
    exit 1
fi
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: The ${PARAM_PASSWORD} environment variable, which password names, is empty or unset." >&2
    echo "  Set it in a context or project environment variable, or pass the name of another variable as password." >&2
    exit 1
fi
oras_require

echo "Logging in to ${REGISTRY} with ORAS..."
if [[ -n "${USERNAME}" ]]; then
    echo "  Username: from ${PARAM_USERNAME}"
else
    echo "  Username: none, since ${PARAM_USERNAME} is empty, so ORAS uses the password as an identity token"
fi
echo "  Password: from ${PARAM_PASSWORD}"
echo "  Plain HTTP: ${PLAIN_HTTP}"

LOGIN_ARGS=(login --password-stdin)
if [[ -n "${USERNAME}" ]]; then
    LOGIN_ARGS+=(--username "${USERNAME}")
fi
if [[ "${PLAIN_HTTP}" == true ]]; then
    LOGIN_ARGS+=(--plain-http)
fi

# The password goes on stdin, never on the command line. printf, not echo:
# echo would take a password of -n or -e as its own option.
printf '%s\n' "${PASSWORD}" | oras "${LOGIN_ARGS[@]}" -- "${REGISTRY}"
