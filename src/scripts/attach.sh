#!/bin/bash
#
# Attaches files to an image or artifact already in a registry for the attach
# command, with oras attach, and exports the digest of the manifest it
# pushed. The attached artifact names the original as its subject, so
# registries list it as one of the original's referrers.

set -euo pipefail

if [[ -z "${SCRIPT_ORAS_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_ORAS_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_ORAS_LIB}"

SUBJECT=$(oras_subst "${PARAM_SUBJECT}")
ARTIFACT_TYPE=$(oras_subst "${PARAM_ARTIFACT_TYPE}")
FILES=$(oras_subst "${PARAM_FILES}")
ANNOTATIONS=$(oras_subst "${PARAM_ANNOTATIONS}")
WORKING_DIR=$(oras_subst "${PARAM_WORKING_DIR}")
PLAIN_HTTP=$(oras_bool plain_http "${PARAM_PLAIN_HTTP}")
EXTRA_ARGS=$(oras_subst "${PARAM_EXTRA_ARGS}")
oras_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"

if [[ -z "${SUBJECT}" ]]; then
    echo "ERROR: subject is required, such as ghcr.io/myorg/myapp@sha256:<digest>." >&2
    exit 1
fi
if [[ -z "${ARTIFACT_TYPE}" ]]; then
    echo "ERROR: artifact_type is required, such as application/spdx+json." >&2
    exit 1
fi
oras_words files "${FILES}"
FILE_LIST=(${ORAS_WORDS[@]+"${ORAS_WORDS[@]}"})
WORKING_DIR=${WORKING_DIR:-.}
if [[ ! -d "${WORKING_DIR}" ]]; then
    echo "ERROR: working_dir '${WORKING_DIR}' is not a directory." >&2
    exit 1
fi
oras_annotation_args "${ANNOTATIONS}"
if [[ "${#FILE_LIST[@]}" -eq 0 && "${#ORAS_ANNOTATION_ARGS[@]}" -eq 0 ]]; then
    echo "ERROR: attach needs files, annotations or both." >&2
    exit 1
fi
oras_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${ORAS_WORDS[@]+"${ORAS_WORDS[@]}"})
oras_require

# oras writes the manifest it pushed here, so its digest can be exported.
MANIFEST=$(mktemp)
trap 'rm -f "${MANIFEST}"' EXIT

ATTACH_ARGS=(attach --artifact-type "${ARTIFACT_TYPE}" --export-manifest "${MANIFEST}")
if [[ "${PLAIN_HTTP}" == true ]]; then
    ATTACH_ARGS+=(--plain-http)
fi
# These arrays can be empty, and bash before 4.4 treats an empty array as
# unset under set -u, so they are expanded only when they have elements.
ATTACH_ARGS+=(${ORAS_ANNOTATION_ARGS[@]+"${ORAS_ANNOTATION_ARGS[@]}"})
ATTACH_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
ATTACH_ARGS+=("${SUBJECT}" ${FILE_LIST[@]+"${FILE_LIST[@]}"})

echo "Attaching ${#FILE_LIST[@]} file(s) to ${SUBJECT} with ORAS..."
echo "  Artifact type: ${ARTIFACT_TYPE}"
echo "  Working directory: ${WORKING_DIR}"
echo "  Plain HTTP: ${PLAIN_HTTP}"
# ORAS stores each file under the path it was given, relative to the
# working directory.
(cd "${WORKING_DIR}" && oras "${ATTACH_ARGS[@]}")

DIGEST=$(oras_manifest_digest "${MANIFEST}")
echo "Attached to ${SUBJECT}, manifest digest ${DIGEST}."
oras_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} for later steps."
