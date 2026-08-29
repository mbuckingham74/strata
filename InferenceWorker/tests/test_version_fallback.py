"""Regression: MLX version must not be 'unknown' solely because mlx.__version__ is absent."""

from __future__ import annotations

import importlib.metadata
import sys
import types


def test_mlx_version_fallback_when_dunder_missing(monkeypatch):
    """When mlx.__version__ is absent, fallback to package metadata must yield real version."""
    # Dummy mlx without __version__
    dummy = types.ModuleType("mlx")
    # Ensure no __version__ attribute
    if hasattr(dummy, "__version__"):
        delattr(dummy, "__version__")
    monkeypatch.setitem(sys.modules, "mlx", dummy)

    orig_version = importlib.metadata.version

    def fake_version(name: str):
        if name == "mlx":
            return "0.31.2"
        return orig_version(name)

    monkeypatch.setattr(importlib.metadata, "version", fake_version)

    from demux_worker.worker import _get_versions

    versions = _get_versions()
    assert versions["mlx"] == "0.31.2"
    assert versions["mlx"] != "unknown"


def test_mlx_version_prefers_dunder_when_present(monkeypatch):
    """When mlx.__version__ is valid, it should be preferred over metadata."""
    dummy = types.ModuleType("mlx")
    dummy.__version__ = "9.9.9"  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", dummy)

    # Metadata would return different value if called — ensure not used
    def fake_version(name: str):
        if name == "mlx":
            return "0.31.2"
        return importlib.metadata.version(name)

    monkeypatch.setattr(importlib.metadata, "version", fake_version)

    from demux_worker.worker import _get_versions

    versions = _get_versions()
    assert versions["mlx"] == "9.9.9"


def test_mlx_version_unknown_only_when_both_mechanisms_fail(monkeypatch):
    """Unknown only if neither __version__ nor metadata can determine version."""
    dummy = types.ModuleType("mlx")
    monkeypatch.setitem(sys.modules, "mlx", dummy)

    def failing_version(name: str):
        raise importlib.metadata.PackageNotFoundError(name)

    monkeypatch.setattr(importlib.metadata, "version", failing_version)

    from demux_worker.worker import _get_versions

    versions = _get_versions()
    assert versions["mlx"] == "unknown"
