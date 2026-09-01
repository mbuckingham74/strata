#!/usr/bin/env python3
"""Generate AboutMetadata.json from InferenceWorker sources.

Derives version/revision data from:
  - InferenceWorker/pyproject.toml  (pinned == versions and git rev)
  - InferenceWorker/uv.lock         (locked versions for >= deps)
  - InferenceWorker/.python-version (python version)

Output is a JSON file bundled into Strata.app and read via Bundle.main.
No repo files are required at runtime.

Usage:
  python3 scripts/generate-about-metadata.py \
    --pyproject InferenceWorker/pyproject.toml \
    --lock InferenceWorker/uv.lock \
    --python-version InferenceWorker/.python-version \
    --output /tmp/AboutMetadata.json
"""

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - fallback for Xcode's system python
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        tomllib = None  # type: ignore


def parse_pyproject(path: Path):
    if tomllib is not None:
        with open(path, "rb") as f:
            data = tomllib.load(f)
        project = data.get("project", {})
        requires_python = project.get("requires-python", "")
        dependencies = project.get("dependencies", [])
    else:
        # Fallback regex parse for old python without tomllib/tomli
        text = path.read_text(encoding="utf-8")
        m = re.search(r'requires-python\s*=\s*["\']([^"\']+)["\']', text)
        requires_python = m.group(1) if m else ""
        # extract dependencies block roughly
        dependencies = re.findall(r'"([^"]+)"', text)
        # keep only those that look like dependencies (contain bs-roformer or == or >=)
        dependencies = [d for d in dependencies if "bs-roformer" in d or "==" in d or ">=" in d or "@" in d]
    # Extract bs-roformer rev and pinned versions
    bs_rev = None
    pinned = {}  # name lower -> version
    for dep in dependencies:
        # git dependency
        if "bs-roformer-infer" in dep:
            m = re.search(r"@([0-9a-f]{7,40})", dep)
            if m:
                bs_rev = m.group(1)
            # version is not in dep spec for git, will be resolved from lock
        else:
            # look for == pin
            m = re.match(r"\s*([A-Za-z0-9_.\-]+)\s*==\s*([^\s;]+)", dep)
            if m:
                name = m.group(1).lower().replace("_", "-")
                ver = m.group(2).strip().strip('"').strip("'")
                pinned[name] = ver
    return requires_python, bs_rev, pinned, dependencies


def parse_lock(path: Path):
    if tomllib is not None:
        with open(path, "rb") as f:
            data = tomllib.load(f)
        packages = data.get("package", [])
        mapping = {}
        for pkg in packages:
            name = pkg.get("name", "").lower().replace("_", "-")
            ver = pkg.get("version", "")
            if name and ver:
                mapping[name] = ver
        return mapping
    # Fallback manual parse
    text = path.read_text(encoding="utf-8")
    mapping = {}
    # uv.lock format: [[package]]\nname = "..."\nversion = "..."
    for block in re.split(r"\[\[package\]\]", text):
        m_name = re.search(r'^name\s*=\s*"([^"]+)"', block, re.MULTILINE)
        m_ver = re.search(r'^version\s*=\s*"([^"]+)"', block, re.MULTILINE)
        if m_name and m_ver:
            name = m_name.group(1).lower().replace("_", "-")
            ver = m_ver.group(1)
            mapping[name] = ver
    return mapping


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pyproject", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--python-version", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    pyproject_path = Path(args.pyproject)
    lock_path = Path(args.lock)
    python_version_path = Path(args.python_version)
    output_path = Path(args.output)

    # Python version from .python-version
    try:
        python_version = python_version_path.read_text(encoding="utf-8").strip()
    except Exception as e:
        print(f"Failed to read {python_version_path}: {e}", file=sys.stderr)
        sys.exit(1)

    requires_python, bs_rev, pinned, _ = parse_pyproject(pyproject_path)
    lock_map = parse_lock(lock_path)

    if not bs_rev:
        print("Failed to extract bs-roformer-infer rev from pyproject.toml", file=sys.stderr)
        sys.exit(1)

    # Resolve versions: prefer pinned == from pyproject, else lock
    def resolve(name_normalized, fallback_key=None):
        key = name_normalized.lower().replace("_", "-")
        if key in pinned:
            return pinned[key]
        # try lock map with hyphen/underscore variants
        if key in lock_map:
            return lock_map[key]
        # fallback: case-insensitive search
        for k, v in lock_map.items():
            if k.lower().replace("_", "-") == key:
                return v
        print(f"Warning: no version found for {name_normalized}", file=sys.stderr)
        return "0.0.0"

    # bs-roformer-infer version comes from lock
    bs_version = lock_map.get("bs-roformer-infer", resolve("bs-roformer-infer"))
    mlx = resolve("mlx")
    mlx_spectro = resolve("mlx-spectro")
    torch_ver = resolve("torch")
    numpy_ver = resolve("numpy")
    soundfile_ver = resolve("soundfile")
    pyyaml_ver = resolve("pyyaml")
    requests_ver = resolve("requests")
    tqdm_ver = resolve("tqdm")
    packaging_ver = resolve("packaging")
    ml_collections_ver = resolve("ml-collections")

    # Short revs to match previous hand-copied literals:
    # version used 14-char prefix, note used 7-char prefix
    short_rev = bs_rev[:14] if len(bs_rev) >= 14 else bs_rev
    note_short_rev = bs_rev[:7] if len(bs_rev) >= 7 else bs_rev

    metadata = {
        "pythonVersion": python_version,
        "pythonRequires": requires_python,
        "bsRoformerInferVersion": bs_version,
        "bsRoformerInferRev": bs_rev,
        "bsRoformerInferShortRev": short_rev,
        "bsRoformerInferNoteRev": note_short_rev,
        "mlx": mlx,
        "mlxSpectro": mlx_spectro,
        "torch": torch_ver,
        "numpy": numpy_ver,
        "soundfile": soundfile_ver,
        "pyyaml": pyyaml_ver,
        "requests": requests_ver,
        "tqdm": tqdm_ver,
        "packaging": packaging_ver,
        "mlCollections": ml_collections_ver,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, sort_keys=False)
        f.write("\n")

    print(f"Wrote {output_path}")


if __name__ == "__main__":
    main()
