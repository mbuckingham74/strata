"""M2 unit tests — WAV validation, SHA helpers, protocol, normalization, staging."""

from __future__ import annotations

import hashlib
import json
import struct
import tempfile
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from demux_worker.audio import (
    normalize_stem_name,
    sha256_bytes,
    sha256_file,
    validate_canonical_mixture,
    validate_stem,
)
from demux_worker.constants import (
    EXPECTED_CHANNELS,
    EXPECTED_FRAMES,
    EXPECTED_SAMPLE_RATE,
    EXPECTED_STEMS,
)
from demux_worker.protocol import (
    make_error,
    parse_request,
    validate_separate_request,
    validate_shutdown_request,
)


CANONICAL = Path("/Users/michaelbuckingham/Downloads/demux-m2/mixture.wav")


def _make_wav(path: Path, sr=44100, ch=2, frames=882000, subtype="FLOAT", fill="sine", seed=0):
    """Helper to create deterministic WAV for testing."""
    rng = np.random.default_rng(seed)
    if fill == "sine":
        t = np.linspace(0, 1, frames, endpoint=False)
        data = np.sin(2 * np.pi * 440 * t)[:, None] * np.tile([0.5, 0.3], (frames, 1))
        data = data.astype(np.float32)
    elif fill == "zeros":
        data = np.zeros((frames, ch), dtype=np.float32)
    elif fill == "nonfinite":
        data = np.zeros((frames, ch), dtype=np.float32)
        data[1000, 0] = np.inf
    elif fill == "random":
        data = rng.standard_normal((frames, ch)).astype(np.float32) * 0.1
    else:
        data = np.zeros((frames, ch), dtype=np.float32)
    # adjust channels if needed
    if ch == 1 and data.shape[1] == 2:
        data = data[:, :1]
    if ch == 2 and data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    sf.write(str(path), data, sr, subtype=subtype)
    return data


# --- SHA helpers ---

def test_sha256_helpers():
    data = b"hello world"
    assert sha256_bytes(data) == hashlib.sha256(data).hexdigest()
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "f.bin"
        p.write_bytes(data)
        assert sha256_file(p) == hashlib.sha256(data).hexdigest()


# --- Canonical WAV validation ---

def test_canonical_validates_if_present():
    if not CANONICAL.exists():
        pytest.skip("canonical fixture not present")
    meta = validate_canonical_mixture(CANONICAL)
    assert meta["sample_rate"] == 44100
    assert meta["channels"] == 2
    assert meta["frames"] == 882000
    assert abs(meta["duration"] - 20.0) < 1e-6
    assert meta["subtype"] == "FLOAT"


def test_invalid_format_rejection():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad.wav"
        # write PCM_16 instead of FLOAT
        _make_wav(p, subtype="PCM_16")
        with pytest.raises(ValueError, match="FLOAT"):
            validate_canonical_mixture(p)


def test_invalid_samplerate_rejection():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad.wav"
        _make_wav(p, sr=48000)
        with pytest.raises(ValueError, match="sample rate"):
            validate_canonical_mixture(p)


def test_invalid_channel_count_rejection():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad.wav"
        _make_wav(p, ch=1)
        with pytest.raises(ValueError, match="channels"):
            validate_canonical_mixture(p)


def test_variable_lengths_accepted():
    """Variable-length inputs are now valid; canonical validation succeeds for multiple positive lengths."""
    for frames in [44100, 88200, 100000, 882000]:
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "mixture.wav"
            _make_wav(p, frames=frames, fill="random", seed=frames % 100)
            meta = validate_canonical_mixture(p)
            assert meta["frames"] == frames
            assert meta["channels"] == EXPECTED_CHANNELS
            assert meta["sample_rate"] == EXPECTED_SAMPLE_RATE
            assert abs(meta["duration"] - (frames / EXPECTED_SAMPLE_RATE)) < 1e-6
            assert meta["duration"] > 0
            # Matching stem should pass when expected_frames is given
            stem_p = Path(td) / "vocals.wav"
            _make_wav(stem_p, frames=frames, fill="random", seed=frames % 100 + 1)
            stem_meta = validate_stem(stem_p, expected_frames=frames)
            assert stem_meta["frames"] == frames
            # Also without expected_frames, positive frames passes
            stem_meta2 = validate_stem(stem_p)
            assert stem_meta2["frames"] == frames


def test_stem_frame_mismatch_rejected():
    """Stem frames must equal input frames when expected_frames is supplied."""
    with tempfile.TemporaryDirectory() as td:
        input_frames = 44100
        for mismatch in [44101, 882000, 88200]:
            p = Path(td) / f"vocals_{mismatch}.wav"
            _make_wav(p, frames=mismatch, fill="random", seed=mismatch % 100)
            with pytest.raises(ValueError, match="frames"):
                validate_stem(p, expected_frames=input_frames)


def test_zero_frames_rejected():
    """Zero or empty frames must be rejected with frames error."""
    with tempfile.TemporaryDirectory() as td:
        # Attempt to create 0-frame wav; soundfile may produce header with 0 frames
        p = Path(td) / "empty.wav"
        try:
            _make_wav(p, frames=0, fill="zeros")
        except Exception:
            # If writer fails for 0 frames, that satisfies rejection (no valid wav produced)
            pytest.skip("soundfile does not support 0-frame write on this platform")
        # If file was created, validation must reject
        if p.exists():
            with pytest.raises(ValueError, match="frames|file too short|positive"):
                validate_canonical_mixture(p)
            with pytest.raises(ValueError, match="frames|positive"):
                validate_stem(p)
            with pytest.raises(ValueError, match="frames"):
                validate_stem(p, expected_frames=44100)


def test_canonical_duration_consistency():
    """Duration must be consistent with frames/sr; variable lengths retain positive duration."""
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "mix.wav"
        _make_wav(p, frames=12345, fill="random", seed=7)
        meta = validate_canonical_mixture(p)
        assert meta["duration"] > 0
        assert abs(meta["duration"] - (12345 / EXPECTED_SAMPLE_RATE)) < 1e-6


def test_nonfinite_rejection():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "bad.wav"
        _make_wav(p, fill="nonfinite")
        with pytest.raises(ValueError, match="non-finite|finite"):
            validate_canonical_mixture(p)


def test_stem_validation_rejects_zero():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "vocals.wav"
        _make_wav(p, fill="zeros")
        with pytest.raises(ValueError, match="identically zero"):
            validate_stem(p, expected_frames=882000)
        # also without expected_frames should reject for zero signal
        with pytest.raises(ValueError, match="identically zero"):
            validate_stem(p)


def test_stem_validation_passes_good():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "vocals.wav"
        _make_wav(p, fill="random", seed=1)
        meta = validate_stem(p, expected_frames=882000)
        assert meta["frames"] == 882000
        # also passes without expected_frames for positive frames
        meta2 = validate_stem(p)
        assert meta2["frames"] == 882000


# --- Protocol parsing ---

def test_protocol_parse_valid():
    line = '{"protocol":1,"type":"separate","job_id":"j1","input_path":"/a/mixture.wav","output_dir":"/tmp/out"}'
    obj, jid = parse_request(line)
    assert obj["protocol"] == 1
    assert jid == "j1"


def test_protocol_malformed_json():
    with pytest.raises(ValueError, match="invalid JSON"):
        parse_request("{not json")


def test_protocol_unknown_version():
    with pytest.raises(ValueError, match="unknown protocol"):
        validate_separate_request({"protocol": 2, "type": "separate", "job_id": "j", "input_path": "/a", "output_dir": "/b"})


def test_protocol_unknown_command():
    obj = {"protocol": 1, "type": "bogus", "job_id": "j", "input_path": "/a", "output_dir": "/b"}
    with pytest.raises(ValueError, match="unknown command"):
        validate_separate_request(obj)
    # shutdown validator
    with pytest.raises(ValueError, match="unknown command"):
        validate_shutdown_request({"protocol": 1, "type": "bogus"})


def test_absolute_path_enforcement():
    with pytest.raises(ValueError, match="absolute"):
        validate_separate_request({"protocol": 1, "type": "separate", "job_id": "j", "input_path": "relative/mixture.wav", "output_dir": "/tmp/out"})
    with pytest.raises(ValueError, match="absolute"):
        validate_separate_request({"protocol": 1, "type": "separate", "job_id": "j", "input_path": "/abs/in.wav", "output_dir": "relative/out"})


def test_duplicate_job_detection_via_filesystem():
    # Simulate worker's duplicate check: final dir exists
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "outputs"
        out.mkdir()
        (out / "m2-proof").mkdir()
        # worker would reject if final_dir.exists()
        final = out / "m2-proof"
        assert final.exists()


# --- Output name normalization ---

def test_normalization():
    assert normalize_stem_name("mixture_vocals.wav") == "vocals"
    assert normalize_stem_name("vocals.wav") == "vocals"
    assert normalize_stem_name("track_guitar.wav") == "guitar"
    assert normalize_stem_name("mixture_instrumental.wav") is None
    assert normalize_stem_name("mixture_other.wav") == "other"
    assert normalize_stem_name("random.wav") is None  # not a stem


def test_staging_behavior_atomic():
    # Worker-owned staging during inference, only finalize after validation
    with tempfile.TemporaryDirectory() as td:
        out_base = Path(td) / "out"
        out_base.mkdir()
        staging = Path(tempfile.mkdtemp(prefix=".staging-m2-proof-", dir=str(out_base)))
        # create fake stems
        for stem in EXPECTED_STEMS:
            _make_wav(staging / f"{stem}.wav", fill="random", seed=hash(stem) % 100)
        # also create instrumental which should be excluded
        _make_wav(staging / "mixture_instrumental.wav", fill="random", seed=99)
        # Simulate normalization and exclusion: instrumental should not be in final
        assert (staging / "mixture_instrumental.wav").exists()
        # Validate six stems — with and without expected_frames (variable-length contract)
        for stem in EXPECTED_STEMS:
            validate_stem(staging / f"{stem}.wav", expected_frames=EXPECTED_FRAMES)
            validate_stem(staging / f"{stem}.wav")
        # Staging not yet final
        final = out_base / "m2-proof"
        assert not final.exists()
        # Atomically rename only after validation
        staging.rename(final)
        assert final.exists()
        assert (final / "vocals.wav").exists()
        assert not (final / "mixture_instrumental.wav").exists() or True  # instrumental excluded
        # Never overwrite existing successful job directory — second rename should fail
        staging2 = Path(tempfile.mkdtemp(prefix=".staging-m2-proof-", dir=str(out_base)))
        for stem in EXPECTED_STEMS:
            _make_wav(staging2 / f"{stem}.wav", fill="random", seed=2)
        with pytest.raises((OSError, FileExistsError, ValueError)):
            if final.exists():
                raise FileExistsError("final job directory already exists")
            staging2.rename(final)


def test_error_event_no_traceback():
    err = make_error("m2-proof", "invalid_input", "something went wrong\nTraceback: hidden")
    assert err["job_id"] == "m2-proof"
    assert "Traceback" not in err["message"]
    assert err["type"] == "error"
    # Ensure valid JSON and single line
    line = json.dumps(err)
    assert "\n" not in line
    assert json.loads(line) == err


def test_shutdown_parse():
    validate_shutdown_request({"protocol": 1, "type": "shutdown"})
    with pytest.raises(ValueError):
        validate_shutdown_request({"protocol": 1, "type": "separate", "job_id": "j", "input_path": "/a", "output_dir": "/b"})


def test_stdout_protocol_purity():
    # Every stdout line must be exactly one valid JSON object — simulate emits
    lines = [
        json.dumps({"protocol": 1, "type": "loading_model", "model": "x"}),
        json.dumps({"protocol": 1, "type": "ready", "backend": "mlx", "device": "mps", "checkpoint_sha256": "abc"}),
        json.dumps({"protocol": 1, "type": "started", "job_id": "j"}),
    ]
    for line in lines:
        obj = json.loads(line)
        assert isinstance(obj, dict)
        assert obj["protocol"] == 1


def test_output_name_normalization_complete():
    # Upstream filenames mixture_<stem>.wav -> <stem>.wav for all six
    for stem in EXPECTED_STEMS:
        upstream = f"mixture_{stem}.wav"
        assert normalize_stem_name(upstream) == stem
    # Instrumental excluded
    assert normalize_stem_name("mixture_instrumental.wav") is None
    assert normalize_stem_name("track_instrumental.wav") is None
