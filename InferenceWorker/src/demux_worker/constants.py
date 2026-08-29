"""Constants for Milestone 2 — exact pinned model/checkpoint metadata."""

from pathlib import Path

# Model registry identifier
MODEL_ID = "roformer-model-bs-roformer-sw-by-jarredou"
CHECKPOINT_FILENAME = "BS-Rofo-SW-Fixed.ckpt"
CHECKPOINT_BYTES = 699412152
CHECKPOINT_SHA256 = "24e7d35ee9c64415673d3fd33e06a67cac2c103c5df6267ba1576459c775916e"
CONFIG_FILENAME = "BS-Rofo-SW-Fixed.yaml"
CONFIG_BYTES = 4613
CONFIG_SHA256 = "f9fada9f94e5ba2d2e4600196299459294bc5f532b314c209cc156ac63e4329b"

# Expected stems and audio format
EXPECTED_STEMS = ["bass", "drums", "other", "vocals", "guitar", "piano"]
EXPECTED_SAMPLE_RATE = 44100
EXPECTED_CHANNELS = 2
EXPECTED_FRAMES = 882000
EXPECTED_DURATION = 20.0
EXPECTED_SUBTYPE = "FLOAT"  # Float32

# Protocol
PROTOCOL_VERSION = 1
CHECKPOINT_COMMIT = "b0f1386fcced25f559f3e61c9f08a73cd9bddf80"

# Cache location outside Git per spec
MODEL_CACHE_ROOT = Path.home() / "Library" / "Caches" / "Demux" / "Models"
MODEL_CACHE_DIR = MODEL_CACHE_ROOT / MODEL_ID
CHECKPOINT_PATH = MODEL_CACHE_DIR / CHECKPOINT_FILENAME
CONFIG_PATH = MODEL_CACHE_DIR / CONFIG_FILENAME

# Output layout helpers
MANIFEST_FILENAME = "manifest.json"
