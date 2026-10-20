#!/bin/bash
#
# Pulls an OCI artifact's files from a registry for the pull command, with
# oras pull.

set -euo pipefail

if [[ -z "${SCRIPT_ORAS_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_ORAS_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_ORAS_LIB}"

REFERENCE=$(oras_subst "${PARAM_REFERENCE}")
OUTPUT_DIR=$(oras_subst "${PARAM_OUTPUT_DIR}")
PLAIN_HTTP=$(oras_bool plain_http "${PARAM_PLAIN_HTTP}")
EXTRA_ARGS=$(oras_subst "${PARAM_EXTRA_ARGS}")

if [[ -z "${REFERENCE}" ]]; then
    echo "ERROR: reference is required, such as ghcr.io/myorg/reports:1.0.0." >&2
    exit 1
fi
OUTPUT_DIR=${OUTPUT_DIR:-.}
oras_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${ORAS_WORDS[@]+"${ORAS_WORDS[@]}"})
oras_require

PULL_ARGS=(pull --output "${OUTPUT_DIR}")
if [[ "${PLAIN_HTTP}" == true ]]; then
    PULL_ARGS+=(--plain-http)
fi
# Empty without extra_args, and bash before 4.4 treats an empty array as
# unset under set -u, so it is expanded only when it has elements.
PULL_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
PULL_ARGS+=("${REFERENCE}")

echo "Pulling ${REFERENCE} with ORAS..."
echo "  Output directory: ${OUTPUT_DIR}"
echo "  Plain HTTP: ${PLAIN_HTTP}"
mkdir -p -- "${OUTPUT_DIR}"
oras "${PULL_ARGS[@]}"
echo "Pulled ${REFERENCE} into ${OUTPUT_DIR}."
