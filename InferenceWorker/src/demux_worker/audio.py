"""Audio validation and hashing for M2 worker."""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path
from typing import Tuple

import numpy as np

try:
    import soundfile as sf
except ImportError:  # pragma: no cover
    sf = None

from .constants import (
    EXPECTED_CHANNELS,
    EXPECTED_DURATION,
    EXPECTED_FRAMES,
    EXPECTED_SAMPLE_RATE,
)


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hex digest of file on disk, streaming."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_wav_info(path: Path) -> dict:
    """Validate WAV container via manual RIFF parse and soundfile read.

    Returns dict with: subtype, sample_rate, channels, frames, duration, format tag.
    Raises ValueError if not valid WAV.
    """
    p = Path(path)
    if not p.exists():
        raise ValueError(f"input file not found: {p}")
    data = p.read_bytes()
    if len(data) < 44:
        raise ValueError("file too short to be WAV")
    riff, size, wave = struct.unpack_from("<4sI4s", data, 0)
    if riff != b"RIFF" or wave != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    # parse chunks
    offset = 12
    fmt_info = None
    data_chunk_size = None
    fmt_tag = None
    n_channels = None
    sr = None
    bits = None
    while offset + 8 <= len(data):
        chunk_id, chunk_size = struct.unpack_from("<4sI", data, offset)
        if chunk_id == b"fmt ":
            if chunk_size < 16:
                raise ValueError("fmt chunk too short")
            wFormatTag, ch, srate, _, _, wBits = struct.unpack_from("<HHIIHH", data, offset + 8)
            fmt_tag = wFormatTag
            n_channels = ch
            sr = srate
            bits = wBits
            fmt_info = (wFormatTag, ch, srate, wBits)
        elif chunk_id == b"data":
            data_chunk_size = chunk_size
            break
        # chunks are padded to even
        offset += 8 + chunk_size + (chunk_size % 2)
    if fmt_info is None:
        raise ValueError("missing fmt chunk")
    if data_chunk_size is None:
        raise ValueError("missing data chunk")
    # For Float32, wFormatTag should be 3 (IEEE FLOAT)
    subtype = "FLOAT" if fmt_tag == 3 and bits == 32 else f"tag={fmt_tag} bits={bits}"
    frames = data_chunk_size // (n_channels * (bits // 8)) if n_channels and bits else 0
    duration = frames / sr if sr else 0
    return {
        "subtype": subtype,
        "format_tag": fmt_tag,
        "sample_rate": sr,
        "channels": n_channels,
        "bits": bits,
        "frames": frames,
        "duration": duration,
        "data_bytes": data_chunk_size,
        "total_bytes": len(data),
    }


def validate_canonical_mixture(path: Path) -> dict:
    """Validate the canonical mixture.wav per spec, raising on mismatch.

    Required:
        File: mixture.wav
        Container: WAV
        Subtype: FLOAT / Float32
        Sample rate: 44100
        Channels: 2
        Frames: 882000
        Duration: 20.0
        Samples: finite
        Signal: non-empty
    Returns metadata dict on success.
    Does not silently convert/resample.
    """
    p = Path(path)
    info = read_wav_info(p)
    if info["format_tag"] != 3:
        raise ValueError(f"expected FLOAT format tag 3, got {info['format_tag']}")
    if info["bits"] != 32:
        raise ValueError(f"expected 32-bit, got {info['bits']}")
    if info["subtype"] != "FLOAT":
        raise ValueError(f"expected FLOAT subtype, got {info['subtype']}")
    if info["sample_rate"] != EXPECTED_SAMPLE_RATE:
        raise ValueError(f"sample rate {info['sample_rate']} != {EXPECTED_SAMPLE_RATE}")
    if info["channels"] != EXPECTED_CHANNELS:
        raise ValueError(f"channels {info['channels']} != {EXPECTED_CHANNELS}")
    if info["frames"] != EXPECTED_FRAMES:
        raise ValueError(f"frames {info['frames']} != {EXPECTED_FRAMES}")
    if abs(info["duration"] - EXPECTED_DURATION) > 1e-6:
        raise ValueError(f"duration {info['duration']} != {EXPECTED_DURATION}")
    # Read samples via soundfile for finite/non-empty checks
    if sf is None:
        raise RuntimeError("soundfile not installed")
    data, sr = sf.read(str(p), dtype="float32", always_2d=True)
    if sr != EXPECTED_SAMPLE_RATE:
        raise ValueError(f"soundfile sr {sr} != {EXPECTED_SAMPLE_RATE}")
    if data.shape != (EXPECTED_FRAMES, EXPECTED_CHANNELS):
        raise ValueError(f"data shape {data.shape} != ({EXPECTED_FRAMES},{EXPECTED_CHANNELS})")
    if not np.isfinite(data).all():
        raise ValueError("samples contain non-finite values")
    if not np.any(data != 0):
        raise ValueError("signal is identically zero (empty)")
    meta = dict(info)
    meta["sha256"] = sha256_file(p)
    meta["samples_finite"] = bool(np.isfinite(data).all())
    meta["non_empty"] = bool(np.any(data != 0))
    meta["max_abs"] = float(np.abs(data).max())
    return meta


def validate_stem(path: Path) -> dict:
    """Validate a final stem per spec:
    WAV, Float32, 44100, stereo, 882000 frames, finite, not identically zero.
    Returns metadata dict.
    """
    p = Path(path)
    info = read_wav_info(p)
    if info["format_tag"] != 3 or info["bits"] != 32:
        raise ValueError(f"stem {p.name} not Float32: tag={info['format_tag']} bits={info['bits']}")
    if info["sample_rate"] != EXPECTED_SAMPLE_RATE:
        raise ValueError(f"stem {p.name} sr {info['sample_rate']} != {EXPECTED_SAMPLE_RATE}")
    if info["channels"] != EXPECTED_CHANNELS:
        raise ValueError(f"stem {p.name} channels {info['channels']} != {EXPECTED_CHANNELS}")
    if info["frames"] != EXPECTED_FRAMES:
        raise ValueError(f"stem {p.name} frames {info['frames']} != {EXPECTED_FRAMES}")
    if sf is None:
        raise RuntimeError("soundfile not installed")
    data, sr = sf.read(str(p), dtype="float32", always_2d=True)
    if not np.isfinite(data).all():
        raise ValueError(f"stem {p.name} contains non-finite values")
    if not np.any(data != 0):
        raise ValueError(f"stem {p.name} is identically zero")
    meta = dict(info)
    meta["sha256"] = sha256_file(p)
    meta["file_size"] = p.stat().st_size
    meta["max_abs"] = float(np.abs(data).max())
    return meta


def normalize_stem_name(filename: str) -> str | None:
    """Normalize upstream filenames such as mixture_vocals.wav -> vocals.wav.

    Returns normalized stem name if recognized, else None to exclude (e.g., instrumental).
    Only the six actual model stems are kept per spec.
    """
    from .constants import EXPECTED_STEMS

    name = Path(filename).stem  # without suffix, but may have mixture_ prefix
    # suffix is .wav expected
    # Handle files like mixture_vocals, vocals, track_drums
    # Upstream does f"{path.stem}_{output_id}.wav" so we take suffix after last underscore
    # For our canonical input mixture.wav, upstream files are mixture_<stem>.wav
    # Normalize by extracting output_id after last underscore if present, else whole stem
    if "_" in name:
        cand = name.rsplit("_", 1)[-1]
    else:
        cand = name
    cand = cand.lower()
    if cand in EXPECTED_STEMS:
        return cand
    # exclude instrumental and others
    return None
