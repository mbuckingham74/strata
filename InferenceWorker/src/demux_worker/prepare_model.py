"""prepare-model command — verified download into ~/Library/Caches/Demux/Models"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path

import requests

from .constants import (
    CHECKPOINT_BYTES,
    CHECKPOINT_FILENAME,
    CHECKPOINT_SHA256,
    CONFIG_BYTES,
    CONFIG_FILENAME,
    CONFIG_SHA256,
    MODEL_CACHE_DIR,
    MODEL_ID,
)

CONNECT_TIMEOUT = 10
READ_TIMEOUT = 60
CHUNK_SIZE = 8192 * 16  # 131k
MAX_RETRIES = 3


def get_file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_file(path: Path, expected_bytes: int, expected_sha: str) -> bool:
    if not path.exists():
        return False
    if path.stat().st_size != expected_bytes:
        print(f"size mismatch {path}: expected {expected_bytes}, got {path.stat().st_size}", file=sys.stderr)
        return False
    actual = get_file_sha256(path)
    if actual.lower() != expected_sha.lower():
        print(f"sha256 mismatch {path}: expected {expected_sha}, got {actual}", file=sys.stderr)
        return False
    return True


def fetch_registry_artifacts():
    """Obtain URLs and metadata from pinned package's registry."""
    try:
        from bs_roformer.checkpoints import artifact_metadata

        ckpt_meta = artifact_metadata(MODEL_ID, "checkpoint")
        cfg_meta = artifact_metadata(MODEL_ID, "config")
        return [
            {
                "filename": CHECKPOINT_FILENAME,
                "url": ckpt_meta["url"],
                "bytes": CHECKPOINT_BYTES,
                "sha256": CHECKPOINT_SHA256,
                "meta": ckpt_meta,
            },
            {
                "filename": CONFIG_FILENAME,
                "url": cfg_meta["url"],
                "bytes": CONFIG_BYTES,
                "sha256": CONFIG_SHA256,
                "meta": cfg_meta,
            },
        ]
    except Exception as e:
        print(f"failed to fetch registry metadata: {e}", file=sys.stderr)
        # fallback to constants but still not inventing alternate sources — use expected URLs from spec
        # These URLs are the canonical HF URLs per checkpoints.toml
        return [
            {
                "filename": CHECKPOINT_FILENAME,
                "url": "https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed/resolve/main/BS-Rofo-SW-Fixed.ckpt",
                "bytes": CHECKPOINT_BYTES,
                "sha256": CHECKPOINT_SHA256,
            },
            {
                "filename": CONFIG_FILENAME,
                "url": "https://huggingface.co/enerjazzer/BS-ROFO-SW-Fixed/resolve/main/BS-Rofo-SW-Fixed.yaml",
                "bytes": CONFIG_BYTES,
                "sha256": CONFIG_SHA256,
            },
        ]


def download_atomic(url: str, dest: Path, expected_bytes: int, expected_sha: str) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(1, MAX_RETRIES + 1):
        tmp_fd, tmp_path_str = tempfile.mkstemp(prefix=f".tmp-{dest.name}.", dir=str(dest.parent))
        os.close(tmp_fd)
        tmp_path = Path(tmp_path_str)
        try:
            print(f"downloading {dest.name} from {url} (attempt {attempt}/{MAX_RETRIES}) ...", file=sys.stderr)
            with requests.get(url, stream=True, timeout=(CONNECT_TIMEOUT, READ_TIMEOUT), headers={"User-Agent": "Demux-prepare-model/1.0"}) as r:
                r.raise_for_status()
                total = int(r.headers.get("content-length", 0))
                if total and total != expected_bytes:
                    print(f"warning: content-length {total} != expected {expected_bytes}", file=sys.stderr)
                with open(tmp_path, "wb") as f:
                    for chunk in r.iter_content(chunk_size=CHUNK_SIZE):
                        if chunk:
                            f.write(chunk)
            # Verify byte count
            actual_size = tmp_path.stat().st_size
            if actual_size != expected_bytes:
                print(f"byte count mismatch for {dest.name}: expected {expected_bytes}, got {actual_size}", file=sys.stderr)
                tmp_path.unlink(missing_ok=True)
                if attempt < MAX_RETRIES:
                    import time as _t; _t.sleep(2)
                    continue
                return False
            actual_sha = get_file_sha256(tmp_path)
            if actual_sha.lower() != expected_sha.lower():
                print(f"sha256 mismatch for {dest.name}: expected {expected_sha}, got {actual_sha}", file=sys.stderr)
                tmp_path.unlink(missing_ok=True)
                if attempt < MAX_RETRIES:
                    import time as _t; _t.sleep(2)
                    continue
                return False
            # Atomic rename only after successful validation
            os.replace(tmp_path, dest)
            print(f"verified {dest.name}: {actual_size} bytes, sha256 {actual_sha[:16]}...", file=sys.stderr)
            return True
        except Exception as e:
            print(f"download failed for {dest.name} (attempt {attempt}/{MAX_RETRIES}): {e}", file=sys.stderr)
            tmp_path.unlink(missing_ok=True)
            if attempt < MAX_RETRIES:
                import time as _t; _t.sleep(2)
                continue
            return False
    return False


def prepare_model(models_dir: Path = MODEL_CACHE_DIR) -> int:
    """Prepare model cache. Returns 0 on success, non-zero on failure."""
    models_dir = Path(models_dir)
    models_dir.mkdir(parents=True, exist_ok=True)
    artifacts = fetch_registry_artifacts()
    success = True
    for art in artifacts:
        dest = models_dir / art["filename"]
        expected_bytes = art["bytes"]
        expected_sha = art["sha256"]
        # revalidate existing
        if dest.exists():
            if verify_file(dest, expected_bytes, expected_sha):
                print(f"exists and valid: {dest} ({expected_bytes} bytes)", file=sys.stderr)
                continue
            else:
                print(f"existing file invalid, removing and re-downloading: {dest}", file=sys.stderr)
                try:
                    dest.unlink()
                except Exception:
                    pass
                # fall through to download
        # download only missing
        ok = download_atomic(art["url"], dest, expected_bytes, expected_sha)
        if not ok:
            print(f"failed to prepare {art['filename']}", file=sys.stderr)
            success = False
        else:
            # double-verify after rename
            if not verify_file(dest, expected_bytes, expected_sha):
                print(f"post-rename verification failed for {dest}", file=sys.stderr)
                success = False
    return 0 if success else 1


def main():
    parser = argparse.ArgumentParser(description="Demux M2 prepare-model — download and verify BS-RoFormer assets")
    parser.add_argument("--models-dir", type=Path, default=MODEL_CACHE_DIR, help="models cache directory")
    parser.add_argument("--check-only", action="store_true", help="only revalidate existing assets, do not download")
    args = parser.parse_args()
    if args.check_only:
        # revalidate only
        ok = True
        for fname, exp_bytes, exp_sha in [
            (CHECKPOINT_FILENAME, CHECKPOINT_BYTES, CHECKPOINT_SHA256),
            (CONFIG_FILENAME, CONFIG_BYTES, CONFIG_SHA256),
        ]:
            p = Path(args.models_dir) / fname
            if not verify_file(p, exp_bytes, exp_sha):
                print(f"check failed: {p}", file=sys.stderr)
                ok = False
            else:
                print(f"check ok: {p}", file=sys.stderr)
        sys.exit(0 if ok else 1)
    sys.exit(prepare_model(args.models_dir))


if __name__ == "__main__":
    main()
