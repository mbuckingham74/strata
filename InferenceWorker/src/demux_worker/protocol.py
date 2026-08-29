"""NDJSON protocol helpers for M2 worker."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Tuple


PROTOCOL_VERSION = 1

VALID_STEMS = ["bass", "drums", "other", "vocals", "guitar", "piano"]


def make_loading_model(model: str) -> Dict[str, Any]:
    return {"protocol": 1, "type": "loading_model", "model": model}


def make_ready(backend: str, device: str, checkpoint_sha256: str) -> Dict[str, Any]:
    return {
        "protocol": 1,
        "type": "ready",
        "backend": backend,
        "device": device,
        "checkpoint_sha256": checkpoint_sha256,
    }


def make_started(job_id: str) -> Dict[str, Any]:
    return {"protocol": 1, "type": "started", "job_id": job_id}


def make_stem(job_id: str, name: str, path: str) -> Dict[str, Any]:
    return {"protocol": 1, "type": "stem", "job_id": job_id, "name": name, "path": path}


def make_done(job_id: str, output_manifest: str) -> Dict[str, Any]:
    return {"protocol": 1, "type": "done", "job_id": job_id, "output_manifest": output_manifest}


def make_error(job_id: str, code: str, message: str) -> Dict[str, Any]:
    # Do not expose tracebacks
    safe_msg = str(message).split("\n")[0][:500]
    return {"protocol": 1, "type": "error", "job_id": job_id, "code": code, "message": safe_msg}


def parse_request(line: str) -> Tuple[Dict[str, Any], str | None]:
    """Parse a raw NDJSON line.

    Returns (parsed_dict, job_id_or_none) or raises ValueError for malformed JSON.
    """
    line = line.strip()
    if not line:
        raise ValueError("empty line")
    try:
        obj = json.loads(line)
    except json.JSONDecodeError as e:
        raise ValueError(f"invalid JSON: {e}") from e
    if not isinstance(obj, dict):
        raise ValueError("request must be JSON object")
    job_id = obj.get("job_id") if isinstance(obj.get("job_id"), str) else None
    return obj, job_id


def validate_separate_request(obj: Dict[str, Any]) -> Tuple[str, Path, Path]:
    """Validate separate request per spec, returning (job_id, input_path, output_dir).

    Raises ValueError with short message for rejection.
    """
    if obj.get("protocol") != PROTOCOL_VERSION:
        raise ValueError(f"unknown protocol version: {obj.get('protocol')}")
    if obj.get("type") != "separate":
        raise ValueError(f"unknown command type: {obj.get('type')}")
    job_id = obj.get("job_id")
    input_path = obj.get("input_path")
    output_dir = obj.get("output_dir")
    if not isinstance(job_id, str) or not job_id:
        raise ValueError("job_id must be non-empty string")
    if not isinstance(input_path, str) or not input_path:
        raise ValueError("input_path must be non-empty string")
    if not isinstance(output_dir, str) or not output_dir:
        raise ValueError("output_dir must be non-empty string")
    # absolute path enforcement
    if not Path(input_path).is_absolute():
        raise ValueError("input_path must be absolute")
    if not Path(output_dir).is_absolute():
        raise ValueError("output_dir must be absolute")
    # further checks (existence, duplicate dir) are handled by caller who has FS context
    return job_id, Path(input_path), Path(output_dir)


def validate_shutdown_request(obj: Dict[str, Any]) -> None:
    if obj.get("protocol") != PROTOCOL_VERSION:
        raise ValueError(f"unknown protocol version: {obj.get('protocol')}")
    if obj.get("type") != "shutdown":
        raise ValueError(f"unknown command type: {obj.get('type')}")
