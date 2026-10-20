#!/bin/bash
#
# Logs out of a registry for the logout command, with oras logout, which
# removes the credentials that login stored.

set -euo pipefail

if [[ -z "${SCRIPT_ORAS_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_ORAS_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_ORAS_LIB}"

REGISTRY=$(oras_subst "${PARAM_REGISTRY}")

if [[ -z "${REGISTRY}" ]]; then
    echo "ERROR: registry is required. Pass the same host that login took." >&2
    exit 1
fi
oras_require

echo "Logging out of ${REGISTRY} with ORAS..."
oras logout "${REGISTRY}"
