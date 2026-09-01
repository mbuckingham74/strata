# Strata

Native macOS app for separating audio into six synchronized stems and mixing them.

Load a YouTube source or a local audio file, play the original, optionally separate it into stems, then mix and export. Audio separation runs locally on this Mac; you do not need to separate a source just to play it or export its original audio as MP3.

## What it does

- Load and play an original mix from YouTube or a local audio file.
- Optionally separate the source into **Vocals, Drums, Bass, Guitar, Piano, and Other**.
- Play the six stems together on one shared timeline.
- Mix with per-stem mute, solo, and 0–100% gain controls.
- Export the original source as MP3, or export individual stems and selected mixes as WAV or MP3.
- Edit MP3 tags and artwork before exporting.

## Get audio

### YouTube

1. Paste an `https://` YouTube URL (`youtube.com` or `youtu.be`) into **Paste YouTube URL**.
2. Click **Load source**.

Strata uses `yt-dlp` to download the source and its available metadata/artwork, then uses FFmpeg to create and validate local audio for the app. Loading a source does not start separation. The loaded card provides original-source playback and, when available, title, artist, channel, and artwork.

After loading, you can use the same local source to:

- **Separate** it into six stems. This reuses the loaded audio and needs the local worker, but not another YouTube download.
- **Save MP3** without separating. This reuses the loaded audio and needs FFmpeg.

Loading a new YouTube URL downloads that source. **Load source** requires both FFmpeg and `yt-dlp`.

### Local file

Click **Add Audio** and choose an audio file. The picker accepts common audio types including MP3, WAV, AIFF, and M4A. The selected file is loaded immediately as the **Original mix** with its filename, duration, and play/pause/seek controls when macOS can decode it.

With a local file loaded, you can:

- **Separate** it. Strata uses FFmpeg to convert it to the canonical audio format needed by the local separation worker, then runs separation locally.
- **Save MP3** without separating. FFmpeg encodes the selected local file directly.

Only one source is active at a time. Choosing a different source clears the previous source's separation result and status.

## Playback and seeking

- The original mix has play/pause, a seek slider, and a time display. Seeking while playing resumes from the new position. After natural completion, Play starts again from the beginning.
- Separated stems stay synchronized on one shared timeline. The compact stems controls, stacked strata view, shared ruler, and any stem waveform can be used to play, pause, or seek all six stems together.
- Times are shown as `m:ss`, or `h:mm:ss` for longer audio.

## Optional six-stratum separation

Separation produces six validated, synchronized stems in this order:

**Vocals → Drums → Bass → Guitar → Piano → Other**

The strata view shows a real waveform for each stem, a shared ruler, and a shared playhead. Click or drag any waveform or the ruler to seek all stems together. The separation status moves through states such as `Ready`, `Downloading…` for YouTube sources, `Loading model…`, `Separating…`, `Complete`, `Failed`, and `Cancelled`. **Cancel** stops the current operation.

## Mixing

Each stem row has:

- **Mute** and **Solo** controls.
- A live **Gain** slider from `0%` to `100%`.

When one or more stems are soloed, only those stems are used for playback and selected-mix export. Otherwise, muted stems are excluded and the remaining stems are used. Gain affects live stem playback and the selected mix export. A selected mix requires at least two stems, and loading a new source resets the stem controls.

## Export

Exports open a save panel. **Export Folder…** sets the default folder shown by future export panels.

### Original source → MP3

- **YouTube source:** use **Save MP3** on the loaded source card. It reuses the downloaded local audio and does not run another `yt-dlp` download.
- **Local file:** use **Save MP3** beside **Separate**. It encodes the selected local file directly.

Original-source MP3 export does not require separation, but all MP3 exports require FFmpeg.

### Individual stem → WAV or MP3

Use the download menu on a stem row to choose WAV or MP3.

- WAV exports copy the validated stem and do not require FFmpeg.
- MP3 exports encode the stem with FFmpeg and can include the current MP3 tags and artwork.

### Selected mix → WAV or MP3

Use **Export Selected MP3** or the menu beside it for **Export Selected WAV**. The selected stems come from the current Mute/Solo state, with Solo taking precedence, and at least two stems must be selected. MP3 mix export requires FFmpeg; WAV mix export does not. Mix export uses the current per-stem gains and keeps the stems aligned.

WAV exports do not contain MP3 tags.

## MP3 tags and filenames

The **MP3 Tags** editor is available for local files and for YouTube sources when metadata is available. It includes **Title, Artist, Album, Album Artist, Year, Track #, Genre**, and artwork controls: **Keep**, **Remove**, or **Replace…**.

Edits are used by MP3 exports for the current source. WAV exports do not carry tags. Blank, `na`, and `n/a` values are omitted; Year accepts four digits, and Track # accepts `n` or `n/m` with positive integers. **Keep** uses available source artwork, **Remove** exports without artwork, and **Replace…** uses the selected image.

Default save names are based on the available metadata and source:

- Original-source MP3: `Artist - Title.mp3` when a metadata-based name is available; otherwise `YouTube Audio.mp3` for YouTube or the local source name, falling back to `Audio.mp3`.
- Individual stem: `Artist - Title - Vocals.mp3` or `.wav` when a source name is available; otherwise `vocals.mp3` or `vocals.wav`.
- Selected mix: the source name followed by the selected stem names, such as `Artist - Title - Vocals + Guitar.mp3`; without a source name, a name such as `Vocals + Guitar.mp3` is used.

The save panel lets you change any default filename before exporting.

## Requirements and setup

- macOS on Apple Silicon.
- FFmpeg executable at `/opt/homebrew/bin/ffmpeg`. It is required for YouTube loading, local separation, and all MP3 exports.
- `yt-dlp` executable at `/opt/homebrew/bin/yt-dlp`. It is required to download YouTube sources. Once a YouTube source is loaded, separating or saving that loaded source does not need another `yt-dlp` run.
- `uv` for the local separation worker. From the repository root:

  ```bash
  cd InferenceWorker
  uv sync
  uv run prepare-model
  ```

  `uv sync` creates the worker environment using the pinned Python version. `uv run prepare-model` is required before the first separation because the worker does not download model assets automatically. To check already prepared assets without downloading, use `uv run prepare-model --check-only`.

When running a Debug build from Xcode, Strata looks for `InferenceWorker/.venv` in the repository. If the worker is elsewhere, set `DEMUX_WORKER_DIRECTORY` to its absolute `InferenceWorker` directory. A worker is needed for separation; WAV exports remain available without FFmpeg once stems exist.

The app shows setup status in the sidebar and Separation card. Missing FFmpeg disables YouTube loading, local separation, and MP3 exports; missing `yt-dlp` disables downloading new YouTube sources; missing the worker disables separation.

## Running

```bash
open Strata.xcodeproj
# Select scheme Strata, destination My Mac, and Run.
```

On first launch, click **Add Audio** for a local file or paste a YouTube URL into **Paste YouTube URL**. Check the setup status if you plan to separate audio.
