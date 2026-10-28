# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb, and set of GitHub Actions, for ORAS (OCI Registry As Storage), the CLI that pushes, pulls and attaches arbitrary files as OCI artifacts in container registries. The orb installs a checksum-verified ORAS and wraps its most used commands.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh

# Tests (offline)
for t in tests/*_test.sh; do bash "$t" || break; done

# Generate SHA-512 checksums (linux amd64 + arm64) for a new ORAS version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - One command per ORAS subcommand, named after it
  - `install.yml` - Installs ORAS with caching and checksum verification
  - `login.yml` / `logout.yml` - `oras login` / `oras logout`
  - `push.yml` - `oras push`, exports the pushed manifest's digest (`digest_env_var`, default `ORAS_PUSHED_DIGEST`)
  - `pull.yml` - `oras pull` into `output_dir`
  - `attach.yml` - `oras attach`, exports the attached manifest's digest (`digest_env_var`, default `ORAS_ATTACHED_DIGEST`)
- `scripts/` - Shell implementations, one per command, included with `<< include(scripts/...) >>`
- `scripts/lib/oras.sh` - Helpers shared by the command scripts. Each command passes it to its step as `SCRIPT_ORAS_LIB: << include(scripts/lib/oras.sh) >>`, and the script `eval`s it after checking it is set. It only defines functions and has no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version
- `../actions/<command>/action.yml` - The GitHub Action for each command (see below)

### Key Implementation Details

**`scripts/install.sh`**: Installs the linux amd64 or arm64 ORAS build (from `uname -m`) from GitHub releases with SHA-512 checksum verification. It follows the layout every juburr orb's install.sh shares: a tool definition (asset names, URLs, archive member, version command), a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"` holding the SHA-512 of the `oras` binary inside the archive. Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading an unlisted version). `tests/install_test.sh` is the install contract test shared by the orbs, and `scripts/cache_key.sh` is shared too; never edit the shared parts in one orb only.

**`scripts/install_hash.sh`**: Prints new checksum table entries. Its `verify_upstream` checks `oras_<version>_checksums.txt` against its OpenPGP signature (`.asc`) and the archive against that list. The public keys come from the ORAS `KEYS` file at the release tag and on `main`, since releases 1.2.2 and 1.2.3 were signed by a key that was only added to `KEYS` later; which keys are trusted is decided by the fingerprints pinned in `ORAS_SIGNING_KEYS`, never by the `KEYS` files. A release signed by an unpinned key fails until the key is checked against the ORAS project and added. Needs `gpg`.

**`scripts/lib/oras.sh`**:
- `oras_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs).
- `oras_words` splits `files` and `extra_args` like shell words with `split_shell_words`, the same parser container-ops-orb uses for `extra_args`: quotes keep spaces, and nothing is expanded or executed. A `$(...)`, backtick or shell operator outside quotes fails the step instead of reaching oras.
- `oras_annotation_args` turns one `key=value` per line into `--annotation` flags, so values keep commas and spaces.
- `oras_manifest_digest` hashes the manifest oras wrote with `--export-manifest`, which every ORAS 1.x release supports. That is how `push` and `attach` get the digest they export, without parsing ORAS's output, which changed across releases.
- `oras_export` writes `export NAME=value` to `$BASH_ENV` with `printf 'export %s=%q\n'`.

**`scripts/login.sh`**: Reads the credentials through indirect expansion of the variable names passed as `username` and `password`, turns xtrace off first, and pipes the password to `oras login --password-stdin` with `printf`. An empty username leaves `--username` out, and ORAS then uses the password as an identity token. An empty password fails the step before oras runs.

**`push.sh` / `attach.sh`**: Run oras in a subshell `cd`'d to `working_dir`, since ORAS stores each file under the path it was given and ORAS 1.0.1 and later refuse absolute paths. The `--export-manifest` file comes from `mktemp` and is removed by the script's EXIT trap.

### GitHub Actions (`actions/`)

Every command has a composite action of the same name in `actions/<command>/action.yml`, with inputs identical to the command's parameters (names and defaults). Each step passes inputs to the orb's script as `PARAM_*` environment variables, as the command does, and runs it with `bash "${GITHUB_ACTION_PATH}/../run_script.sh" SCRIPT SCRIPT_ORAS_LIB=<lib>`. Inputs never appear inside a `run:` script. `push` and `attach` take `working_dir` as their scripts do, through `PARAM_WORKING_DIR`. `install` restores and saves `actions/cache` with the command's key ingredients. `login`'s credentials come from the variables its inputs name, which a workflow sets in the `env` of the step that uses it. Every `uses:` is pinned to a commit SHA with its version in a comment.

`actions/run_script.sh` and `tests/actions_test.sh` are identical in every juburr orb that ships actions; never edit them here alone. Keep the actions in sync with the command YAML by hand or with an equivalent generator, and quote any default a YAML 1.1 reader would take for a boolean or number: every input is a string. Without the CircleCI CLI, `oras_subst` uses values as they are, so the action descriptions leave out "Environment variables are expanded". `tests/actions_test.sh` checks all of this.

### CI Pipeline

- `.circleci/config.yml` - Setup workflow: `test-install` (install contract), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/login_test.sh` and `tests/commands_test.sh` against a stand-in oras), `test-actions` (`tests/actions_test.sh`), orb-tools lint, pack and review, shellcheck.
- `test-deploy.yml` - `command-test`, `checksum-test` (an unlisted release candidate fails closed; `known_versions` installs it), `arm64-test` (Arm machine, second install from cache), and `registry-test`, a matrix over ORAS 1.0.0 and the default version that runs every command against a `registry:2` with htpasswd auth on a machine executor: the exported digest must match the registry's, pulled files must match, the attached artifact must show up in `oras discover`, and a pull must fail after `logout`. Publishing runs on `v*` tags.
- `.github/workflows/actions.yml` - The actions on GitHub's runners: `offline-tests`; `install` (amd64 and arm64, a second install from the cache, an unlisted version failing); `install-from-cache` (the download hosts blocked); and `registry`, which mirrors `registry-test` (ORAS 1.0.0 and the default against a `registry:2` with htpasswd auth, started with `docker run`), plus a login with a wrong password that must fail.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `oras_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `login.sh` runs `set +o xtrace` with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. The tests run the scripts with the bash first on the `PATH`, so put a bash 4.3 there to check this locally.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_ORAS_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names are ORAS's own subcommands. Parameters that map onto one ORAS flag take its long name in snake_case (`artifact_type`, `plain_http`, `output_dir` for `--output`). Plumbing matches the other juburr orbs: credentials are `env_var_name` parameters named `username` and `password` (defaults `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`, shared with container-ops-orb and helm-orb), variables a command writes are `<thing>_env_var`, and pass-through arguments are `extra_args`.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh` to lint shell scripts
- Run every `tests/*_test.sh`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml` to validate the orb structure
- For changes to a command, also run it against a real registry with `plain_http`, under ORAS 1.0.0 and the default version, as `registry-test` does
