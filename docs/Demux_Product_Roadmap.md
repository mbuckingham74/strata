# Demux Product Roadmap

Demux is a personal native macOS music source-separation app.

Long-term architecture:

```text
YouTube URL
    ↓
yt-dlp
    ↓
FFmpeg
    ↓
canonical 44.1 kHz stereo PCM
    ↓
BS-RoFormer / MLX
    ↓
native AVFoundation multistem playback/mixing
```

The roadmap should stay incremental. Each version should feel like a complete, useful product rather than accumulating unrelated features.

---

## V1 — Separate + Play

### Goal

Paste a YouTube URL, separate the song into stems, and play those stems back independently or together.

### Features

- Paste a YouTube URL
- Acquire source media with `yt-dlp`
- Decode/remux/resample/canonicalize with FFmpeg
- Produce canonical 44.1 kHz stereo PCM
- Run BS-RoFormer source separation through MLX
- Produce six stems:
  - vocals
  - drums
  - bass
  - guitar
  - piano
  - other
- Native synchronized multistem playback with AVFoundation
- Play / pause
- Seek
- Solo individual stems
- Mute individual stems
- Preserve exact synchronization between stems

### Non-goals

- No user-facing stem export yet
- No advanced mixing
- No waveform editor
- No DAW-style editing

### Product story

```text
Get song → separate → listen
```

---

## V2 — Export

### Goal

Allow separated stems, or selected combinations of stems, to be saved for use outside Demux.

### Features

- Export an individual stem
- Export multiple selected stems as a mixed file
- MP3 export
- Preserve WAV export as a lossless option
- Automatically derive artist/title metadata from YouTube where reliable
- Human-readable filenames

### Example naming

Single stem:

```text
Artist - Song Title - Vocals.mp3
Artist - Song Title - Drums.mp3
Artist - Song Title - Guitar.mp3
```

Combined stems:

```text
Artist - Song Title - Vocals + Guitar.mp3
Artist - Song Title - Drums + Bass.mp3
```

### Product story

```text
Get song → separate → save stems
```

---

## V3 — Mixer

### Goal

Turn Demux from a stem player into a lightweight interactive music mixer.

### Features

Per-stem controls:

```text
Vocals   [Mute] [Solo]  ───── Volume
Drums    [Mute] [Solo]  ───── Volume
Bass     [Mute] [Solo]  ───── Volume
Guitar   [Mute] [Solo]  ───── Volume
Piano    [Mute] [Solo]  ───── Volume
Other    [Mute] [Solo]  ───── Volume
```

Additional controls:

- Independent volume per stem
- Mute
- Solo
- Master volume
- Export the current custom mix
- Preserve exact sample synchronization while adjusting levels

Potential one-click presets:

- Instrumental
- Vocals only
- No vocals
- Drums + bass
- Custom

### Product story

```text
Get song → separate → mix → export mix
```

---

## V4 — Local File Input

### Goal

Allow Demux to process local audio files in addition to YouTube URLs.

### Features

- Drag-and-drop local files
- Open files through the standard macOS file picker
- Support common formats such as:
  - MP3
  - WAV
  - FLAC
  - M4A/AAC
- Canonicalize all supported inputs through the existing FFmpeg ingest boundary
- Feed the same canonical PCM format into the existing inference pipeline

### Architectural principle

YouTube and local files should converge on the same canonicalization boundary:

```text
YouTube URL ──→ yt-dlp ──┐
                         ├─→ FFmpeg → canonical PCM → MLX
Local file ──────────────┘
```

---

## V5 — Projects / History

### Goal

Avoid rerunning expensive inference for songs that have already been separated.

### Features

- Remember previously processed songs
- Reopen an existing Demux project instantly
- Persist:
  - source metadata
  - canonical input identity
  - stem locations
  - model identity
  - separation metadata
  - mix state where useful
- Reuse existing stems when valid
- Clearly distinguish project data from disposable caches

### Storage principle

Required project/model data should live in persistent macOS application storage, not ephemeral locations such as `/tmp` or `~/Library/Caches`.

---

## V6 — Playback / Practice Tools

### Goal

Make Demux more useful for studying and practicing music.

### Candidate features

- Loop a selected section
- A/B playback ranges
- Keyboard shortcuts
- Jump forward/backward
- Better timeline navigation
- Optional waveform overview

Keep these features playback-oriented rather than turning Demux into a DAW.

---

## V7 — Model Choices

### Goal

Allow different separation models when they provide meaningful quality or workflow benefits.

### Candidate features

- Alternative BS-RoFormer models
- Specialized vocal/instrumental models
- 2-stem models
- 4-stem models
- Higher-quality or future 6-stem models
- Model metadata and integrity verification
- Per-model performance/quality information

### Architectural principle

The inference boundary should remain abstract enough that adding a new validated model does not disturb playback, projects, ingest, or export.

---

## Deliberate Scope Restraint

Do not automatically add these to early versions:

- Full waveform editing
- EQ
- Effects chains
- Pitch shifting
- Tempo/time stretching
- Recording
- Lyrics
- Playlists
- Multitrack editing
- DAW-style clip manipulation

These may be considered later if they solve a real personal workflow need.

The early product spine should remain:

```text
V1  Get song → separate → listen
V2  Get song → separate → save stems
V3  Get song → separate → mix → export mix
```

That sequence gives Demux a complete, useful progression while preserving the existing architectural boundaries.
