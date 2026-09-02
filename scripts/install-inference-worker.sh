#!/usr/bin/env bash
# install-inference-worker.sh
#
# Purpose:
#   Install the V1 Strata InferenceWorker to its canonical installed location.
#   This is a setup/update-time installer only; normal runtime invokes the
#   worker directly via python and does not depend on uv or the repository
#   checkout.
#
# V1 installed worker:
#   Creates a non-editable, locked environment for the demux-worker package
#   from the repository's InferenceWorker project. The installed site-packages
#   contains the worker code with no runtime dependency on the checkout.
#
# Canonical location:
#   $HOME/Library/Application Support/Strata/InferenceWorker/.venv
#   Parent directory $HOME/Library/Application Support/Strata is ensured to
#   exist but is never deleted or replaced by this script. Only
#   "$HOME/Library/Application Support/Strata/InferenceWorker/.venv" is managed.
#   Do NOT bundle or copy a .venv into Strata.app and do NOT add an Xcode
#   Copy Files phase for the worker environment.
#
# Notes:
#   - uv is used for setup/update only; runtime remains direct python.
#   - Uses the existing locked InferenceWorker project at $repo_root/InferenceWorker.

set -euo pipefail

# Derive repository root relative to this script's location.
# Supports both direct execution and sourcing via BASH_SOURCE.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Canonical V1 installed worker root (quoted to handle "Application Support" space).
worker_root="$HOME/Library/Application Support/Strata/InferenceWorker"
project_dir="$repo_root/InferenceWorker"
uv_bin="/opt/homebrew/bin/uv"

# Fail clearly if uv is missing at the expected Homebrew location.
if [[ ! -x "$uv_bin" ]]; then
  echo "error: uv not found or not executable at $uv_bin. Install uv via Homebrew to /opt/homebrew/bin/uv." >&2
  exit 1
fi

# Fail clearly if the locked InferenceWorker project files are missing.
if [[ ! -f "$project_dir/pyproject.toml" ]]; then
  echo "error: missing $project_dir/pyproject.toml" >&2
  exit 1
fi
if [[ ! -f "$project_dir/uv.lock" ]]; then
  echo "error: missing $project_dir/uv.lock" >&2
  exit 1
fi
if [[ ! -f "$project_dir/.python-version" ]]; then
  echo "error: missing $project_dir/.python-version" >&2
  exit 1
fi

# Ensure the canonical parent exists without ever removing Application Support/Strata or Projects.
# Only "$worker_root/.venv" is managed; never delete parent directories wholesale.
# If cleaning is needed, only "$worker_root/.venv" may be removed.
mkdir -p "$worker_root"

# Create/sync the environment directly at its final Application Support path.
# Install demux-worker non-editably so site-packages contains the code with no
# runtime dependency on the repository checkout.
# uv is setup/update only; normal runtime remains direct python (do not add uv to runtime).
UV_PROJECT_ENVIRONMENT="$worker_root/.venv" /opt/homebrew/bin/uv sync --project "$repo_root/InferenceWorker" --locked --no-dev --no-editable --managed-python --reinstall-package demux-worker

# Verify the installed python exists before invoking model preparation.
if [[ ! -x "$worker_root/.venv/bin/python3" ]]; then
  echo "error: expected python not found at $worker_root/.venv/bin/python3 after uv sync" >&2
  exit 1
fi

# Reuse valid model cache and prepare any missing model artifacts.
"$worker_root/.venv/bin/python3" -m demux_worker prepare-model
