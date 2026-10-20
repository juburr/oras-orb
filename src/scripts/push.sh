#!/bin/bash
#
# Pushes files to a registry as an OCI artifact for the push command, with
# oras push, and exports the digest of the manifest it pushed.

set -euo pipefail

if [[ -z "${SCRIPT_ORAS_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_ORAS_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_ORAS_LIB}"

REFERENCE=$(oras_subst "${PARAM_REFERENCE}")
FILES=$(oras_subst "${PARAM_FILES}")
ARTIFACT_TYPE=$(oras_subst "${PARAM_ARTIFACT_TYPE}")
ANNOTATIONS=$(oras_subst "${PARAM_ANNOTATIONS}")
WORKING_DIR=$(oras_subst "${PARAM_WORKING_DIR}")
PLAIN_HTTP=$(oras_bool plain_http "${PARAM_PLAIN_HTTP}")
EXTRA_ARGS=$(oras_subst "${PARAM_EXTRA_ARGS}")
oras_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"

if [[ -z "${REFERENCE}" ]]; then
    echo "ERROR: reference is required, such as ghcr.io/myorg/reports:1.0.0." >&2
    exit 1
fi
oras_words files "${FILES}"
FILE_LIST=(${ORAS_WORDS[@]+"${ORAS_WORDS[@]}"})
if [[ "${#FILE_LIST[@]}" -eq 0 ]]; then
    echo "ERROR: files is required: the files to push, separated by spaces or newlines, with quotes around a path that has spaces." >&2
    exit 1
fi
WORKING_DIR=${WORKING_DIR:-.}
if [[ ! -d "${WORKING_DIR}" ]]; then
    echo "ERROR: working_dir '${WORKING_DIR}' is not a directory." >&2
    exit 1
fi
oras_annotation_args "${ANNOTATIONS}"
oras_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${ORAS_WORDS[@]+"${ORAS_WORDS[@]}"})
oras_require

# oras writes the manifest it pushed here, so its digest can be exported.
MANIFEST=$(mktemp)
trap 'rm -f "${MANIFEST}"' EXIT

PUSH_ARGS=(push --export-manifest "${MANIFEST}")
if [[ -n "${ARTIFACT_TYPE}" ]]; then
    PUSH_ARGS+=(--artifact-type "${ARTIFACT_TYPE}")
fi
if [[ "${PLAIN_HTTP}" == true ]]; then
    PUSH_ARGS+=(--plain-http)
fi
# Both arrays can be empty, and bash before 4.4 treats an empty array as unset
# under set -u, so they are expanded only when they have elements.
PUSH_ARGS+=(${ORAS_ANNOTATION_ARGS[@]+"${ORAS_ANNOTATION_ARGS[@]}"})
PUSH_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
# After --, a file or reference that starts with "-" is not read as a flag.
PUSH_ARGS+=(-- "${REFERENCE}" "${FILE_LIST[@]}")

echo "Pushing ${#FILE_LIST[@]} file(s) to ${REFERENCE} with ORAS..."
echo "  Working directory: ${WORKING_DIR}"
echo "  Artifact type: ${ARTIFACT_TYPE:-<ORAS default>}"
echo "  Plain HTTP: ${PLAIN_HTTP}"
# ORAS stores each file under the path it was given, relative to the
# working directory.
(cd -- "${WORKING_DIR}" && oras "${PUSH_ARGS[@]}")

DIGEST=$(oras_manifest_digest "${MANIFEST}")
echo "Pushed ${REFERENCE}, manifest digest ${DIGEST}."
oras_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} for later steps."
