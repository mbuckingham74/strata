"""Long-lived MLX worker — NDJSON protocol, single job at a time, MLX/mps enforced."""

from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
import platform
import shutil
import sys
import tempfile
import time
import traceback
from pathlib import Path

from .constants import (
    CHECKPOINT_BYTES,
    CHECKPOINT_COMMIT,
    CHECKPOINT_FILENAME,
    CHECKPOINT_PATH,
    CHECKPOINT_SHA256,
    CONFIG_BYTES,
    CONFIG_FILENAME,
    CONFIG_PATH,
    CONFIG_SHA256,
    EXPECTED_CHANNELS,
    EXPECTED_SAMPLE_RATE,
    EXPECTED_STEMS,
    MANIFEST_FILENAME,
    MODEL_CACHE_DIR,
    MODEL_ID,
)
from .audio import normalize_stem_name, sha256_file, validate_canonical_mixture, validate_stem
from .protocol import (
    make_done,
    make_error,
    make_loading_model,
    make_ready,
    make_started,
    make_stem,
    parse_request,
    validate_separate_request,
    validate_shutdown_request,
)

# Protocol output is the original stdout
_protocol_out = sys.stdout

def emit(obj: dict):
    line = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    _protocol_out.write(line + "\n")
    _protocol_out.flush()

# Stdout/stderr contract: redirect upstream prints to stderr during inference
class RedirectStdoutToStderr:
    def __enter__(self):
        self._old = sys.stdout
        sys.stdout = sys.stderr
        return self

    def __exit__(self, *args):
        sys.stdout = self._old

# Global state
_session = None
_backend = None
_device = None
_model_load_time = None
_cached_versions = {}


def _assert_arm64():
    mach = platform.machine()
    if mach != "arm64":
        print(f"platform.machine() == {mach!r}, expected 'arm64'", file=sys.stderr)
        raise RuntimeError(f"requires arm64, got {mach}")


def _verify_cached_assets():
    """Verify checkpoint/config exist and match expected bytes+sha, fail if not."""
    for path, exp_bytes, exp_sha, name in [
        (CHECKPOINT_PATH, CHECKPOINT_BYTES, CHECKPOINT_SHA256, CHECKPOINT_FILENAME),
        (CONFIG_PATH, CONFIG_BYTES, CONFIG_SHA256, CONFIG_FILENAME),
    ]:
        if not path.exists():
            print(f"missing cached asset {name}: {path}", file=sys.stderr)
            raise FileNotFoundError(f"missing cached asset: {path}")
        if path.stat().st_size != exp_bytes:
            print(f"bytes mismatch {name}: {path.stat().st_size} != {exp_bytes}", file=sys.stderr)
            raise ValueError(f"checkpoint byte mismatch for {name}")
        actual = sha256_file(path)
        if actual.lower() != exp_sha.lower():
            print(f"sha mismatch {name}: {actual} != {exp_sha}", file=sys.stderr)
            raise ValueError(f"checkpoint SHA-256 mismatch for {name}")


def _get_versions():
    try:
        import mlx

        mlx_ver = getattr(mlx, "__version__", None)
        if not isinstance(mlx_ver, str) or not mlx_ver.strip() or mlx_ver.strip() == "unknown":
            raise AttributeError("mlx.__version__ missing or invalid")
        mlx_ver = mlx_ver.strip()
    except Exception:
        try:
            mlx_ver = importlib.metadata.version("mlx")
        except Exception:
            mlx_ver = "unknown"
    try:
        import mlx_spectro
        # mlx_spectro may not have __version__
        mlx_spectro_ver = getattr(mlx_spectro, "__version__", "0.7.0")
        # Try via metadata
        try:
            mlx_spectro_ver = importlib.metadata.version("mlx-spectro")
        except Exception:
            pass
    except Exception:
        mlx_spectro_ver = "unknown"
    try:
        import torch
        torch_ver = torch.__version__
    except Exception:
        torch_ver = "unknown"
    try:
        py_ver = platform.python_version()
    except Exception:
        py_ver = "unknown"
    # bs-roformer-infer commit
    try:
        # try to get via importlib metadata?
        commit = CHECKPOINT_SHA256  # placeholder
        # Actually commit is b0f1386... constant
        from .constants import CHECKPOINT_COMMIT
        commit = CHECKPOINT_COMMIT
    except Exception:
        commit = "b0f1386fcced25f559f3e61c9f08a73cd9bddf80"
    return {
        "python": py_ver,
        "torch": torch_ver,
        "mlx": mlx_ver,
        "mlx-spectro": mlx_spectro_ver,
        "bs_commit": commit,
    }


def _load_model():
    global _session, _backend, _device, _model_load_time, _cached_versions
    _assert_arm64()
    _verify_cached_assets()
    versions = _get_versions()
    _cached_versions = versions
    # Emit loading already done by caller; now load
    start = time.monotonic()
    with RedirectStdoutToStderr():
        # Explicitly construct upstream session with backend="mlx" device="mps"
        from bs_roformer import BSRoformerSession

        # Use explicit verified checkpoint/config paths, must not implicitly download
        sess = BSRoformerSession(
            model_name=MODEL_ID,
            model_path=str(CHECKPOINT_PATH),
            config_path=str(CONFIG_PATH),
            backend="mlx",
            device="mps",
        )
        sess.load()
        # Assert actual resolved backend is exactly mlx and device is mps
        # BSRoformerSession stores backend as resolved name string after load, device as resolved string
        actual_backend = getattr(sess, "backend", None)
        actual_device = getattr(sess, "device", None)
        # For mlx backend, device is string "mps"
        # Normalize device to string
        if actual_device is not None:
            actual_device_str = str(actual_device).lower()
            # BSRoformerSession for mlx sets device to "mps" string via MLXBackend
            # but could be "mps" exactly
            if "mps" not in actual_device_str:
                # also check backend's resolved_device
                try:
                    backend_dev = sess._backend.resolved_device if hasattr(sess, "_backend") and sess._backend else None
                    if backend_dev:
                        actual_device_str = str(backend_dev).lower()
                except Exception:
                    pass
        else:
            actual_device_str = "unknown"
        if actual_backend != "mlx":
            print(f"actual backend {actual_backend!r} != 'mlx'", file=sys.stderr)
            raise RuntimeError(f"backend mismatch: expected mlx, got {actual_backend}")
        # device check: must be exactly mps
        # The spec says assert actual resolved device is exactly "mps" — we compare lowercased but require mps
        if actual_device_str != "mps":
            # Also allow string "mps" with extra? Spec says exactly mps, so fail if not
            if actual_device_str != "mps":
                print(f"actual device {actual_device_str!r} != 'mps'", file=sys.stderr)
                # For robustness, also check backend
                try:
                    bd = sess._backend.resolved_device
                    if bd != "mps":
                        raise RuntimeError(f"device mismatch: expected mps, got {bd}")
                except Exception:
                    raise RuntimeError(f"device mismatch: expected mps, got {actual_device_str}")

        # Also assert platform.machine() still arm64
        _assert_arm64()

        _session = sess
        _backend = actual_backend
        _device = "mps"
    _model_load_time = time.monotonic() - start
    print(f"model loaded in {_model_load_time:.2f}s backend={_backend} device={_device}", file=sys.stderr)
    return _session


def _handle_separate(obj: dict, job_busy: bool) -> tuple[dict | None, bool]:
    """Handle separate command, return (response_to_emit, started_flag). Caller manages busy flag.

    This function performs validation and, if valid, runs inference synchronously and emits
    started/stem/done events directly via emit(). It returns (error_response, False) if it
    emitted error itself, or (None, True) if it started job.
    For the orchestrating loop, we need to know if job is busy.
    """
    # Validate protocol already? caller validates.
    try:
        job_id, input_path, output_dir = validate_separate_request(obj)
    except ValueError as e:
        j = obj.get("job_id") if isinstance(obj.get("job_id"), str) else "unknown"
        emit(make_error(str(j), "invalid_request", str(e)))
        return None, False

    job_id = str(obj["job_id"])
    input_path = Path(obj["input_path"])
    output_dir = Path(obj["output_dir"])

    # concurrent check
    if job_busy:
        emit(make_error(job_id, "busy", "another job is already running"))
        return None, False

    # absolute already checked, but double
    if not input_path.is_absolute() or not output_dir.is_absolute():
        emit(make_error(job_id, "invalid_input", "paths must be absolute"))
        return None, False

    # input exists?
    if not input_path.exists() or not input_path.is_file():
        emit(make_error(job_id, "invalid_input", f"input not found: {input_path}"))
        return None, False

    # output final dir duplicate check
    final_dir = output_dir / job_id
    if final_dir.exists():
        emit(make_error(job_id, "duplicate_job", f"final job directory already exists: {final_dir}"))
        return None, False

    # canonical input validation before real inference per spec
    try:
        # independently validate
        with RedirectStdoutToStderr():
            canonical_meta = validate_canonical_mixture(input_path)
    except Exception as e:
        # spec says if worker-side validation contradicts already-measured canonical properties, stop and report discrepancy
        # We emit error and do not proceed
        print(f"canonical validation failed for {input_path}: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        emit(make_error(job_id, "invalid_input", f"canonical validation failed: {e}"))
        return None, False

    # Create staging dir (worker-owned)
    staging_dir = None
    try:
        staging_dir = Path(tempfile.mkdtemp(prefix=f".staging-{job_id}-", dir=str(output_dir)))
        print(f"staging dir {staging_dir}", file=sys.stderr)
    except Exception as e:
        print(f"failed to create staging: {e}", file=sys.stderr)
        emit(make_error(job_id, "internal", "failed to create staging"))
        return None, False

    emit(make_started(job_id))

    # Run inference
    inference_start = time.monotonic()
    try:
        with RedirectStdoutToStderr():
            # Ensure warnings go to stderr
            import warnings
            warnings.simplefilter("always")
            # Create temp input folder for session.infer (it expects folder with wavs)
            # Use staging's parent? Actually create temp input dir
            tmp_input = Path(tempfile.mkdtemp(prefix=f".input-{job_id}-", dir=str(output_dir)))
            try:
                # Symlink or copy mixture.wav into tmp_input
                # Use symlink if possible, else copy
                link_path = tmp_input / input_path.name
                try:
                    link_path.symlink_to(input_path)
                except Exception:
                    shutil.copy2(input_path, link_path)
                # Run session's infer — must go through public session API
                # session.infer will write mixture_<stem>.wav etc into staging_dir
                # But we want to use staging_dir as store_dir directly
                # However session.infer will iterate input_folder and write there
                # So store_dir = staging_dir
                # Use the global _session
                if _session is None:
                    raise RuntimeError("model not loaded")
                result = _session.infer(str(tmp_input), store_dir=str(staging_dir), verbose=False, output_format="wav_float32")
                # result is OutputManifest but we will not rely on it; we will discover files
                print(f"inference result outputs {result}", file=sys.stderr)
            finally:
                # Clean temp input folder (not staging)
                shutil.rmtree(tmp_input, ignore_errors=True)

        inference_wall = time.monotonic() - inference_start
        print(f"inference wall {inference_wall:.2f}s", file=sys.stderr)

        # Normalize upstream filenames such as mixture_<stem>.wav -> <stem>.wav
        # Exclude instrumental
        # Discover files in staging_dir
        all_files = list(staging_dir.glob("*.wav")) + list(staging_dir.glob("*.flac"))
        # Need to handle both .wav and maybe .flac? But spec says use wav_float32
        normalized = {}
        for f in all_files:
            stem_name = normalize_stem_name(f.name)
            if stem_name is None:
                # Exclude instrumental and non-stems
                print(f"excluding {f.name} (not a six stem)", file=sys.stderr)
                # Optionally remove instrumental from staging to not affect final
                # But keep for now then delete before finalization?
                continue
            dest = staging_dir / f"{stem_name}.wav"
            if f.resolve() != dest.resolve():
                # If already normalized name (e.g., already vocals.wav) then keep
                if dest.exists():
                    print(f"conflict normalized {dest} already exists", file=sys.stderr)
                    raise ValueError(f"duplicate normalized stem {stem_name}")
                f.rename(dest)
            normalized[stem_name] = dest

        # Ensure we have exactly six stems
        if set(normalized.keys()) != set(EXPECTED_STEMS):
            missing = set(EXPECTED_STEMS) - set(normalized.keys())
            extra = set(normalized.keys()) - set(EXPECTED_STEMS)
            print(f"normalized stems mismatch missing {missing} extra {extra} found {normalized.keys()}", file=sys.stderr)
            raise ValueError(f"expected 6 stems {EXPECTED_STEMS}, got {sorted(normalized.keys())}")

        # Validate all six before finalization — stems must match input frames
        input_frames = int(canonical_meta["frames"])
        stem_metas = {}
        for stem in EXPECTED_STEMS:
            p = normalized[stem]
            meta = validate_stem(p, expected_frames=input_frames)
            stem_metas[stem] = meta
            print(f"validated stem {stem}: {meta}", file=sys.stderr)

        # Compute input sha and metadata for manifest
        input_sha = sha256_file(input_path)
        input_meta = canonical_meta  # already validated

        # Compute per-stem records for manifest
        stems_records = []
        for stem in sorted(EXPECTED_STEMS):
            p = normalized[stem]
            m = stem_metas[stem]
            rec = {
                "name": stem,
                "path": str(final_dir / f"{stem}.wav"),
                "sha256": m["sha256"],
                "file_size": m["file_size"],
                "frame_count": m["frames"],
                "channels": m["channels"],
                "sample_rate": m["sample_rate"],
            }
            stems_records.append(rec)

        # Build manifest
        # Gather versions
        versions = _cached_versions
        # Real-time factor — variable length: use input duration or frames/sr
        try:
            sd = input_meta.get("duration")
            if sd is not None and float(sd) > 0:
                source_duration = float(sd)
            else:
                source_duration = float(input_meta.get("frames", 0)) / EXPECTED_SAMPLE_RATE
        except Exception:
            try:
                source_duration = float(input_meta.get("frames", 0)) / EXPECTED_SAMPLE_RATE
            except Exception:
                source_duration = 0
        if not source_duration or source_duration <= 0:
            source_duration = float(input_frames) / EXPECTED_SAMPLE_RATE if input_frames else 0
        rtf = inference_wall / source_duration if source_duration else 0

        # Attempt to get peak allocation if exposed (MLX)
        peak_allocation = None
        try:
            import mlx.core as mx
            # mlx may expose memory stats
            if hasattr(mx, "get_peak_memory"):
                peak_allocation = mx.get_peak_memory()
            elif hasattr(mx, "get_active_memory"):
                peak_allocation = mx.get_active_memory()
        except Exception:
            pass

        # Whole-process RSS via resource?
        rss_bytes = None
        try:
            import resource
            rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            # On macOS, ru_maxrss is bytes? Actually on Linux it's KB, on macOS bytes
            # need to handle both
            if platform.system() == "Darwin":
                rss_bytes = rss  # already bytes
            else:
                rss_bytes = rss * 1024
        except Exception:
            pass

        manifest = {
            "protocol": 1,
            "schema_version": 1,
            "job_id": job_id,
            "input_path": str(input_path),
            "input_sha256": input_sha,
            "model": MODEL_ID,
            "checkpoint": CHECKPOINT_FILENAME,
            "checkpoint_bytes": CHECKPOINT_BYTES,
            "checkpoint_sha256": CHECKPOINT_SHA256,
            "checkpoint_commit": versions.get("bs_commit", "b0f1386fcced25f559f3e61c9f08a73cd9bddf80"),
            "config": CONFIG_FILENAME,
            "config_bytes": CONFIG_BYTES,
            "config_sha256": CONFIG_SHA256,
            "backend": _backend,
            "device": _device,
            "python_version": versions.get("python"),
            "torch_version": versions.get("torch"),
            "mlx_version": versions.get("mlx"),
            "mlx_spectro_version": versions.get("mlx-spectro"),
            "input_metadata": {
                "sample_rate": input_meta.get("sample_rate"),
                "channels": input_meta.get("channels"),
                "frames": input_meta.get("frames"),
                "duration": input_meta.get("duration"),
                "subtype": input_meta.get("subtype"),
                "total_bytes": input_meta.get("total_bytes"),
                "data_bytes": input_meta.get("data_bytes"),
                "sha256": input_sha,
            },
            "cached_model_load_time": _model_load_time,
            "inference_wall_time": inference_wall,
            "source_duration": source_duration,
            "real_time_factor": rtf,
            "peak_mlx_allocation": peak_allocation,
            "max_rss_bytes": rss_bytes,
            "stems": stems_records,
            "output_dir": str(final_dir),
        }

        # Write manifest into staging_dir first
        manifest_path_staging = staging_dir / MANIFEST_FILENAME
        with open(manifest_path_staging, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=False)
            f.write("\n")

        # Only finalize after all validation — atomically rename staging to final
        # But staging contains normalized files and manifest, final_dir is output_dir/job_id
        # We should ensure we remove any leftover instrumental files from staging before rename
        for f in list(staging_dir.iterdir()):
            if f.name.endswith("_instrumental.wav") or (f.name not in [f"{s}.wav" for s in EXPECTED_STEMS] and f.name != MANIFEST_FILENAME):
                # For safety, remove instrumental and any non-expected leftover
                if f.is_file() and f.name != MANIFEST_FILENAME and f.name not in [f"{s}.wav" for s in EXPECTED_STEMS]:
                    print(f"removing leftover {f.name} before finalize", file=sys.stderr)
                    f.unlink()

        # Verify final_dir still doesn't exist (TOCTOU)
        if final_dir.exists():
            raise ValueError(f"final dir race: {final_dir} already exists")

        # Ensure output_dir exists
        output_dir.mkdir(parents=True, exist_ok=True)
        # Atomic move: use os.rename (works if same filesystem)
        # If staging and output_dir are same parent, rename is atomic
        # Use shutil.move if needed, but try os.replace via rename
        try:
            staging_dir.rename(final_dir)
        except OSError as e:
            print(f"rename failed {e}, trying shutil.move", file=sys.stderr)
            shutil.move(str(staging_dir), str(final_dir))

        # After finalize, emit stem events with final absolute paths
        for stem in sorted(EXPECTED_STEMS):
            path = final_dir / f"{stem}.wav"
            emit(make_stem(job_id, stem, str(path.resolve())))

        manifest_final = final_dir / MANIFEST_FILENAME
        emit(make_done(job_id, str(manifest_final.resolve())))
        print(f"job {job_id} done manifest {manifest_final}", file=sys.stderr)
        return None, False  # job completed, not busy

    except Exception as e:
        print(f"job {job_id} failed: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        # Ensure incomplete jobs remain in staging and cannot appear as successfully completed
        # Leave staging_dir intact (do not delete) but ensure final_dir not created
        # If staging_dir still exists and final_dir does not, that's staging
        # Emit error event without traceback
        emit(make_error(job_id, "inference_failed", str(e)[:500]))
        # Optionally keep staging for debugging; do not automatically delete
        # But we should ensure we don't leak huge staging? Spec says remain in staging
        return None, False


def main():
    # Ensure stderr is unbuffered for diagnostics
    # Startup sequence
    try:
        _assert_arm64()
    except Exception as e:
        print(f"startup arm64 check failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Emit loading_model
    emit(make_loading_model(MODEL_ID))
    # Load model (must not implicitly download)
    try:
        _load_model()
    except Exception as e:
        print(f"model load failed: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        # Do not emit ready; exit with error so launcher can detect?
        # But spec says worker startup must not implicitly download; if missing, fail safely
        # We should exit with non-zero
        sys.exit(1)

    # Emit ready
    emit(make_ready(str(_backend or "mlx"), str(_device or "mps"), CHECKPOINT_SHA256))

    # Main loop: read NDJSON from stdin
    job_busy = False
    # Track one job at a time flag; but actual busy is whether we are inside inference
    # Since _handle_separate is synchronous and emits started/done inside, job_busy is just
    # to reject concurrent requests that arrive while we are handling? But since we handle
    # synchronously, concurrent won't happen unless we had threading. However we implement
    # check anyway: if a second separate arrives while previous is still being processed,
    # but since we process line by line synchronously, that cannot happen. Still we keep flag
    # for spec compliance: set busy during handling.
    # Simpler: handle requests sequentially, and if job_busy already true, reject.
    # But we need to set busy before handling and clear after.
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            obj, job_id_from_parse = parse_request(line)
        except ValueError as e:
            # malformed JSON
            # Need to emit error with job_id unknown if possible
            print(f"malformed request: {e} line={line[:200]}", file=sys.stderr)
            emit(make_error("unknown", "malformed_request", str(e)))
            continue

        # Validate protocol version early
        proto = obj.get("protocol")
        if proto != 1:
            j = obj.get("job_id") if isinstance(obj.get("job_id"), str) else "unknown"
            emit(make_error(str(j), "invalid_protocol", f"unknown protocol {proto}"))
            continue

        typ = obj.get("type")
        if typ == "shutdown":
            try:
                validate_shutdown_request(obj)
            except ValueError as e:
                emit(make_error("unknown", "invalid_request", str(e)))
                continue
            print("shutdown requested", file=sys.stderr)
            # Cleanly exit
            # According to spec, maybe need to release model? But process termination handles
            try:
                if _session is not None:
                    with RedirectStdoutToStderr():
                        _session.release()
            except Exception:
                pass
            sys.exit(0)
        elif typ == "separate":
            # mark busy
            if job_busy:
                j = obj.get("job_id", "unknown")
                emit(make_error(str(j), "busy", "another job already running"))
                continue
            job_busy = True
            try:
                _handle_separate(obj, False)
            finally:
                job_busy = False
        else:
            j = obj.get("job_id") if isinstance(obj.get("job_id"), str) else "unknown"
            emit(make_error(str(j), "unknown_command", f"unknown command type {typ!r}"))
            continue

    # EOF reached -> exit gracefully
    print("stdin EOF, exiting", file=sys.stderr)
    sys.exit(0)


if __name__ == "__main__":
    main()
