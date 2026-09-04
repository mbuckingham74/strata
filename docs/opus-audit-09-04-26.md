# Strata — Read-Only Audit

**Date:** 2026-09-04 · **Commit:** `c5774df` (main, clean) · **Scope:** whole repo, read-only

## Method

Read all 39 Swift sources (~16k lines), the Python worker (~1.2k lines), the Xcode project,
the build/install scripts, and `AGENTS.md`. No code was modified. No tests, builds, or
inference runs were executed — per `AGENTS.md`, a read-only audit does not invalidate
existing evidence, and running the suite would have been disproportionate. Every finding
below was derived by reading the source; each cites a file and line.

Severity is my judgement of user impact × likelihood, not a formal scale.

---

## At a glance

| # | Finding | Severity |
|---|---------|----------|
| C1 | Unbounded-output pipe deadlock in all five synchronous `liveRun` helpers — first-run setup can hang forever with no timeout or cancel | **High** |
| C2 | `AudioProcessRunner` gives yt-dlp a stdout `Pipe()` nobody reads | **High** |
| C3 | `resetForNewSession()` / `adoptCompleted()` orphan the in-flight task; next action fails with "already running" | **High** |
| B1 | "Save MP3" is a dead button after the first cancel on a preview-only source | **High** |
| B2 | Scratch is never reclaimed — ~2× the track leaks to disk per Create Strata | **High** |
| C12 | A latched cleanup failure silently disables three buttons with no message | Medium |
| B3 | FFmpeg, yt-dlp and uv are downloaded and executed with no integrity check (Node is verified) | Medium |
| C6 | Persist and reopen do large synchronous file I/O on the main thread | Medium |
| C7 | Audio-device changes are never observed — playback dies silently | Medium |
| B4 | Exact-version pinning of yt-dlp guarantees eventual breakage with no update path | Medium |
| C5 | Result validation blocks the worker actor; Cancel and Quit stall behind it | Medium |
| C4 | `AudioProcessRunner` ownership can be clobbered across cancel/run | Medium |
| B5 | Worker reads whole WAVs into memory just to parse a header | Medium |
| C8 | Playback "complete" fires on `dataConsumed`, not `dataPlayedBack` | Low |
| C9, C10, C11, C13, B6–B12 | See detail below | Low |

---

# Part 1 — Concurrency and race conditions

## C1. Unbounded-output pipe deadlock in every synchronous `liveRun` helper — **High**

`Strata/Inference/WorkerProvisioner.swift:191`, `FFmpegAvailability.swift:241`,
`NodeAvailability.swift:271`, `YtDlpAvailability.swift:235`, `UvAvailability.swift:150`
all share this shape:

```swift
try process.run()
process.waitUntilExit()                                    // blocks here
let outData = outPipe.fileHandleForReading.readDataToEndOfFile()   // drains after
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
```

The child's stdout and stderr are pipes with no reader while the parent is parked in
`waitUntilExit()`. Once ~64 KiB accumulates in either pipe buffer, the child blocks on
`write(2)` and never exits; the parent never returns from `waitUntilExit()`. Classic
mutual deadlock, and there is **no timeout and no cancel path** anywhere on this route.

Why this matters here specifically:

- It is the **first-launch setup path**. `InferenceController.runSetup` dispatches each
  step into `Task.detached` and `await`s it (`InferenceController.swift:260-377`). A hung
  child leaves the checklist pinned on "Preparing…" permanently — `InferenceSetupView`
  offers "Try Again" only in the `.failed` state, which is never reached.
- The children are the chattiest processes in the app: `uv sync --reinstall-package`
  (dependency resolution over ~40 packages, and an arbitrarily long stderr dump on a
  resolution failure), `python -m demux_worker prepare-model` (a 699 MB download),
  `/usr/bin/tar` and `/usr/bin/unzip` extracting the FFmpeg archive.
- The failure paths are worse than the success paths: a *successful* `uv sync` prints a
  few KB, but a *failing* one prints the full resolver diagnostic — so the deadlock is
  most likely exactly when the user most needs the error message.

`liveDownload` in `FFmpegAvailability.swift:270` and `NodeAvailability.swift:300` has the
same ordering; there stdout is `nullDevice` and only curl's `-sS` stderr is at risk, so
the exposure is smaller but the pattern is identical.

**The codebase already contains the correct implementation.** `RuntimeReadinessChecker.captureVersionOutput`
(`RuntimeReadiness.swift:338-460`) drains both pipes concurrently via `readabilityHandler`,
enforces a hard deadline, escalates SIGTERM → SIGINT → SIGKILL, and uses non-blocking
reads so a descendant holding the write end can't stall it. That helper (generalised to
take a timeout) should replace all five `liveRun` bodies.

## C2. `AudioProcessRunner` never drains the child's stdout — **High**

`Strata/Ingest/AudioIngestSupport.swift:67`

```swift
process.standardInput = FileHandle.nullDevice
let stderrPipe = Pipe()
process.standardError = stderrPipe
process.standardOutput = Pipe()      // ← created, never read
```

stderr is drained by a `readabilityHandler`; stdout is not read by anything, ever. This
runner drives **yt-dlp** for all three YouTube paths (`ingestWithMetadata`, `fetchPreview`,
`downloadAudioOnly`) and ffmpeg for local ingest.

yt-dlp writes `[youtube] Extracting URL`, `[info] Downloading…`, `[download] Destination:`
and per-update download progress to **stdout**. With a non-tty stdout it emits each
progress update on its own line rather than overwriting with `\r`, so a slow or long
download accumulates hundreds of lines. Past ~64 KiB, yt-dlp blocks writing, and
`run()`'s `while isRunningCheck(process)` loop (`AudioIngestSupport.swift:86`) spins at
10 ms forever. The only escape is the user pressing Cancel.

ffmpeg is safe here only by accident — it writes to stderr and its stdout is empty because
the output is a file path, not `-`.

Fix is one line: `process.standardOutput = FileHandle.nullDevice`, since nothing reads it.
If yt-dlp progress is ever wanted for a progress bar, drain it the way stderr is drained.

## C3. `resetForNewSession()` and `adoptCompleted()` orphan the in-flight task — **High**

Every `startSeparation*` method carefully chains the task it supersedes:

```swift
let previousTask = currentTask
previousTask?.cancel()
currentTask = Task { [previousTask] in
    if let previousTask { await previousTask.value }   // transitive ownership
    await self.drainCleanupChain()
```

and `cancel()` (`InferenceController.swift:1488`) enqueues cleanup onto `cleanupChainTail`,
which itself `await`s `taskToCancel`. That discipline is sound.

`resetForNewSession()` (`:614`) and `adoptCompleted()` (`:635`) break it:

```swift
currentTask?.cancel()
currentTask = nil          // handle discarded — nothing joins it, nothing enqueues it
```

Both are reachable from ordinary UI: **New Session** (toolbar `+` and sidebar `+` →
`SessionStore.newSession`) and **clicking a Library row** (`SessionStore.reopen` →
`adoptCompleted`). Both are enabled while a separation or ingest is running.

Consequences:

1. The orphaned task is still inside `InferenceWorkerClient.runSeparationImpl`, holding
   `separationReserved = true` and `activeJob` until its `catch` completes — which runs
   `settleWorkerAfterSeparationFailure` → `terminateWorker` → SIGTERM (5 s grace) → SIGKILL
   (1 s grace) under `.ordinary` policy. For up to ~6.5 s afterwards, a new **Create Strata**
   throws `.alreadyRunningJob` and the user sees *"A separation is already running"*
   (`InferenceProtocol.swift:51`) on a fresh, empty session.
2. Neither method calls `youTubeIngest.cancel()` or `localIngest.cancel()`. A running
   yt-dlp download keeps going after New Session, and `YouTubeIngestClient.activeRunDirectory`
   stays set — so **Add YouTube Source** throws `.alreadyRunning` (*"Ingest already running"*)
   until the abandoned download finishes on its own.

The fix mirrors what `cancel()` already does: route both through the cleanup chain
(cancel ingests, append the dying task to `cleanupChainTail`) rather than dropping the handle.

## C4. `AudioProcessRunner` ownership can be clobbered across cancel/run — **Medium**

`AudioIngestSupport.swift:36-148`. `cancel()` terminates the process and sets
`activeProcess = nil` while `run()` is still suspended in its 10 ms poll loop. When `run()`
resumes it unconditionally executes `activeProcess = nil` (`:110`) — which, if a *newer*
`run()` has meanwhile registered its own process, erases that registration. After that,
`hasActiveProcess()` reports false while a child is live: the "already running" guard in
`YouTubeIngestClient.ingestWithMetadata` passes, a second yt-dlp can start, and a later
`cancel()` won't terminate the live one (orphan process).

The same shape exists one layer up: `YouTubeIngestClient`'s `catch` block clears
`activeRunDirectory` (`:418`) without checking whether it still owns the directory it
created.

Today this is *latent* — the controller's task chaining serialises these calls. But the
invariant is enforced in the wrong layer, and **C3 is precisely the path where the chaining
is skipped.** Guard both with identity checks: `guard activeProcess === process else { return }`
and `guard activeRunDirectory == runDir else { … }`.

## C5. Result validation blocks the worker actor — **Medium**

`InferenceWorkerClient.swift:807-811` handles the `done` event inside the stdout consumer
task and calls `await validateAndComplete(...)` (`:1096`), which runs
`SeparationValidator.validatedResult` **synchronously on the actor**. That function opens
7 `AVAudioFile`s and SHA-256s the input plus all six stems, and `sha256File`
(`SeparationResult.swift:144`) uses `Data(contentsOf:)` — the whole file into memory,
per file.

While it runs, nothing else can enter `InferenceWorkerClient`: not `cancelActiveJob`, not
`terminateForApplicationExit`, not the timeout finishers. So **Cancel and Quit both stall
for the whole validation window.**

For a 4-minute track (~290 MB across 7 files, page-cache-warm) that is a few hundred
milliseconds — unnoticeable. It scales linearly with track length and is unbounded when
Scratch points at a slow or external volume, which is exactly what the Settings pane
invites (`StrataApp.swift:281`). Two changes make it robust: hop validation to
`Task.detached` and re-enter the actor with the finished result, and stream the hash with
`SHA256()` + chunked `FileHandle.read(upToCount:)` — the pattern already used in
`RuntimeReadinessChecker.defaultFileSHA256` (`RuntimeReadiness.swift:171`).

## C6. Main-thread file I/O on the completion and reopen paths — **Medium**

`SessionStore` is `@MainActor` and its persistence calls are synchronous.

**On completion** — `ContentView.swift:781`, inside `.onChange(of: inferenceController.result)`:
`handleCompletedSeparation` (`SessionStore.swift:77`) → `StrataProjectPersistence.persistAssets`
(`:264`). That function copies every asset **twice** (stage, then commit) plus a **third**
copy of any pre-existing destination (backup) — for a YouTube re-separation that is roughly
3× ~300 MB of `FileManager.copyItem` on the main thread. Staging goes to
`fileManager.temporaryDirectory`, which is on the boot volume: if the user has moved the
Library to an external drive, none of those copies can be APFS clones and transient disk
use triples.

**On re-separation only**, `handleCompletedSeparation` additionally calls
`persistedJobId(for:)` → `loadSeparationResult` → a full validation pass with all seven
SHA-256s, also on the main thread, *before* the copying starts.

**On reopen** — `SessionStore.reopen` (`:292`) → `persistence.loadSeparationResult`
(`StrataProjectPersistence.swift:481`) → `SeparationValidator.validatedResult(forProjectDirectory:)`,
which hashes the mixture and all six stems synchronously. Clicking a Library row therefore
beachballs the UI for as long as it takes to read and hash the whole project.

The staging→backup→commit→rollback design is genuinely good (see Part 3); it just needs to
run off the main actor with progress, and reopen should validate in the background.

## C7. Audio-device configuration changes are never observed — **Medium**

Neither `AVAudioEngineTransport` (`AudioTransport.swift`) nor `MultiStemAudioTransport`
registers for `NSNotification.Name.AVAudioEngineConfigurationChange`.

When the user unplugs headphones, connects an interface, or switches the system output
device, `AVAudioEngine` stops and posts that notification. Strata never hears it: the engine
is stopped, audio is gone, but `_isPlaying` stays `true`, `PlaybackController.isPlaying`
stays `true`, and the 0.1 s timer keeps sampling a `currentTime` that no longer advances.
The transport looks like it is playing and is not. Recovery requires the user to guess at
pause-then-play.

For a six-stem mixer this is the most likely everyday audio bug in the app. Handling it
means observing the notification, re-`connect`ing each player to `mainMixerNode` with the
current format, restarting the engine, and rescheduling from the last known frame.

## C8. Natural completion fires on `dataConsumed`, not `dataPlayedBack` — **Low**

`AudioTransport.swift:215,226` and `MultiStemAudioTransport.swift:374,386` use
`scheduleFile(_:at:completionHandler:)` / `scheduleSegment(_:startingFrame:frameCount:at:completionHandler:)`.
Those overloads deliver `.dataConsumed` semantics — the handler runs when the player has
consumed the data, not when it has finished rendering it. `handleEngineCompletion` therefore
sets `seekFrame = totalFrames` and `isPlaying = false`, and the playhead snaps to the end,
slightly before the audio actually stops.

In the six-stem case only the leader (index 0) carries a handler, so the group is declared
complete on the leader's consumption specifically. Use the
`completionCallbackType: .dataPlayedBack` overloads.

## C9. Sample-synchronous start is best-effort — **Low**

`MultiStemAudioTransport.play()` and `seek(to:)` compute one `AVAudioTime` from
`mach_absolute_time() + 50 ms` and pass it to all six `player.play(at:)` calls
(`:223`, `:271`). If `engine.start()` on a cold engine takes longer than 50 ms —
plausible on first play after a device change — the anchor is already in the past, and
`play(at:)` with a past time means "start as soon as possible" *per node*, independently.
Six independent starts is exactly what the design is trying to avoid.

Anchoring on a sample time derived from `engine.outputNode.lastRenderTime` instead of wall
clock removes the assumption.

## C10. Unbounded `AsyncStream` buffers for worker stdout/stderr — **Low**

`InferenceWorkerClient.swift:674,727` use `AsyncStream.makeStream()`, whose default
buffering policy is `.unbounded`. The `readabilityHandler` yields on a background queue
regardless of whether the actor is consuming. The Python worker runs inference with
`verbose=True` and redirects upstream stdout to stderr (`worker.py:56-62`), so stderr is
high-volume. When the actor is blocked (C5), those chunks accumulate in memory with no
cap — the 32 KiB `stderrTail` bound applies only *after* consumption. `.bufferingNewest(n)`
on the stderr stream costs nothing and bounds it.

## C11. `precondition` in the reader-start path can crash a release build — **Low**

`InferenceWorkerClient.swift:671,726`:

```swift
precondition(stdoutTask == nil && stdoutContinuation == nil)
```

`precondition` traps in Release (unlike `assert`). Every other invariant violation in this
file throws a typed `InferenceError.startupFailure`. If the `hasResidualLifecycleResources`
gate is ever wrong, the difference is a hard crash instead of a legible error. Throwing
matches the file's own conventions.

## C12. A latched cleanup failure silently disables three buttons — **Medium**

Commit `1048d82` ("Surface cleanup failure recovery block") added
`surfaceBlockedNewWorkAfterCleanupFailure()` so Create Strata never appears to do nothing.
Four sibling entry points were not updated and still return silently:

| Method | Line | Behaviour after a latched failure |
|---|---|---|
| `prepareYouTubeMP3Export(youTubeURL:)` | `:947` | `if youTubeCleanupFailed { return }` |
| `loadYouTubeSource(youTubeURL:)` | `:1053` | `if youTubeCleanupFailed { return }` |
| `prepareYouTubeMP3ExportFromLoadedSource()` | `:1141` | `if youTubeCleanupFailed { return nil }` |
| `prepareYouTubeMP3ExportFromLoadedPreview()` | `:1241` | `if youTubeCleanupFailed { return }` |

So after a cleanup failure, **Add YouTube Source** and **Save MP3** are dead — clicking them
produces no state change, no status text, no alert. There is also an inconsistency: these
four check only `youTubeCleanupFailed`, while the separation entry points check
`hasLatchedCleanupFailure` (either flag). Route all of them through the same helper.

## C13. Cross-generation state clobber on `cleanupFailed` — **Low**

`InferenceController.swift:750-760` (local) and `:902-912` (YouTube) — the `.cleanupFailed`
branch writes `state`, `statusMessage` and `errorMessage` **before** the
`guard generation == self.latestGeneration` check that governs every other write in the
file. A superseded operation's cleanup failure therefore overwrites a newer operation's UI.

It is arguably intentional, since the latch is process-wide, but it is the one place the
generation discipline is broken and it reads as a bug. Cleaner: set the latch flag outside
the guard (it is global) and write the UI inside it.

---

# Part 2 — Correctness and product bugs

## B1. "Save MP3" is a dead button after the first cancel on a preview-only source — **High**

The save panel is driven by value equality:

```swift
.onChange(of: inferenceController.preparedYouTubeMP3Export) { _, preparation in
    guard let preparation else { return }
    exportYouTubeMP3(preparation)
}
```
(`ContentView.swift:784-787`)

`prepareYouTubeMP3ExportFromLoadedPreview()` (`InferenceController.swift:1241`) has a reuse
branch that sets metadata and `state = .idle` but **does not reassign
`preparedYouTubeMP3Export`** (`:1274-1281`). `onChange` therefore does not fire.

Reproduction:

1. Paste a YouTube URL → **Add YouTube Source** (metadata-only preview; `loadedYouTubeSource` stays nil).
2. **Save MP3** → audio-only download → save panel opens → press **Cancel**.
3. **Save MP3** again → the reuse branch runs → nothing happens. The button is dead for the rest of the session.

`hasLoadedYouTubeAudioFile` requires `loadedYouTubeSource`, which the `downloadAudioOnly`
path deliberately never sets (to avoid feeding WebM to `PlaybackController`), so the button
always takes the dead branch. Fix: invoke the export directly from the reuse branch, or
drive the panel from an explicit request counter rather than value identity.

## B2. Scratch is never reclaimed — ~2× the track leaks per Create Strata — **High**

There is no cleanup of scratch anywhere in the app. `removeItem` appears only on failure and
cancellation paths (`YouTubeIngestClient`, `LocalAudioIngestClient`, the tool installers,
`StemExporter` temporaries). On the **success** path:

- `M4Ingest/<uuid>/mixture.wav` (or `LocalIngest/<uuid>/mixture.wav`) is kept forever —
  `YouTubeIngestClient.swift:396-399` clears `activeRunDirectory` but leaves the directory.
- `M3Separations/<jobId>/` keeps all six stems plus the manifest forever.
- Both are then **copied again** into `~/Library/Application Support/Strata/Projects/<id>/`,
  so the same audio exists in two or three places.

For a 5-minute track that is roughly 300 MB in the Library plus another ~300 MB stranded in
Scratch, per separation, permanently.

The Python worker adds to it: `_handle_separate` deliberately leaves `.staging-<job>-*`
behind on failure ("Ensure incomplete jobs remain in staging", `worker.py:515-521`), and
`.input-<job>-*` also survives a SIGKILL during inference since only the `finally` cleans it
(`worker.py:295,322`). Nothing ever collects either.

Defaults land in `~/Library/Caches/Strata`, which macOS *may* purge under pressure — but a
user-chosen Scratch folder (Settings → Locations) will not be touched by anyone.

## B3. Third-party binaries are installed without integrity verification — **Medium**

The model checkpoint gets byte-count + SHA-256 + a native `TrustedInferenceIdentity` anchor,
re-verified at every launch (`RuntimeReadiness.checkModel`) and again inside the worker
(`worker.py:_verify_cached_assets`). The executables that actually process the user's audio
get far less:

| Tool | Source | Verified? |
|---|---|---|
| Node | `nodejs.org/dist/…tar.gz` | **Yes** — pinned SHA-256 checked via `shasum` (`NodeAvailability.swift:74,324`) |
| FFmpeg | `https://evermeet.cx/ffmpeg/ffmpeg-9.0.1.7z` (`FFmpegAvailability.swift:61`) | No — downloaded, extracted, `chmod 755`, executed |
| yt-dlp | GitHub release `yt-dlp_macos` (`YtDlpAvailability.swift:61`) | No |
| uv | `curl -LsSf https://astral.sh/uv/<v>/install.sh \| … sh` (`UvAvailability.swift:118`) | No — remote script piped to a shell |

Node already demonstrates the pattern the other three need. Pinning a SHA-256 per version
is a few lines each; where a checksum isn't practical (uv's installer), verifying the
resulting binary's `codesign`/notarisation status before first execution is the next best
control. Worth aligning simply because the asymmetry is surprising given how carefully the
checkpoint is handled.

## B4. Exact-version pinning of yt-dlp guarantees breakage with no update path — **Medium**

`ExternalToolResolver.resolveYtDlp()` accepts a tool only when
`v == ExternalToolCompatibility.ytDlpSupportedVersion` (`"2026.08.19"`), and `resolveFFmpeg()`
likewise requires exactly `"9.0.1"`. Only Node uses range semantics (`major >= 22`).

Two consequences:

1. **yt-dlp will stop working.** YouTube changes its extractors constantly; yt-dlp ships
   fixes weekly. A hard-pinned build breaks and Strata has no way out — it will *reject* a
   newer copy the user installs via Homebrew and re-provision the same stale pinned version.
   The user's only recourse is editing a constant and rebuilding.
2. **Redundant downloads.** A user with a perfectly capable Homebrew FFmpeg 8.x is told
   "FFmpeg version mismatch" and made to download a second copy.

Suggest minimum-version semantics for FFmpeg and yt-dlp (as Node already has), plus an
explicit "Update yt-dlp" action in Settings that fetches the latest release.

## B5. The worker reads whole WAVs into memory to parse a header — **Medium**

`InferenceWorker/src/demux_worker/audio.py:44` — `read_wav_info` does `data = p.read_bytes()`,
loading the entire file, purely to walk RIFF chunks in the first few hundred bytes. Then
`validate_canonical_mixture` / `validate_stem` call `sf.read(..., dtype="float32")`, which
materialises the whole decoded array again.

That is ~2× the file size transient, and it happens once for the mixture and once for each
of the six stems. For a 10-minute track: ~212 MB per file, ~425 MB transient each, seven
times — on top of the loaded BS-RoFormer model. On a 16 GB Mac this pushes toward swap
during the most memory-sensitive part of the job.

Both fixes are small: parse the header from a bounded `f.read(4096)` loop, and use
`sf.info()` plus `sf.blocks()` for the finite / non-identically-zero checks.

## B6. The worker cannot be cancelled cooperatively — **Low**

`_handle_separate` runs `_session.infer(...)` synchronously and `main`'s
`for raw_line in sys.stdin` doesn't read again until it returns (`worker.py:317`, `:561`). So
cancellation is always SIGTERM/SIGKILL from the Swift side, which discards the loaded model
and costs the next job a fresh ~2-minute load. A reader thread setting a flag the inference
loop checks (or chunked inference) would let Cancel keep the engine warm — which matters a
lot given how expensive model load is.

## B7. Dead busy-check in `_handle_separate` — **Low**

`main` always calls `_handle_separate(obj, False)` (`worker.py:606`), so the `if job_busy:`
branch inside (`worker.py:239`) can never fire. The check that matters is the one in
`main`. Harmless, but it hides where the real invariant lives.

## B8. `isUsableArtwork`'s magic-byte checks are decorative — **Low**

`YouTubeIngestClient.swift:799-811` ends with:

```swift
return bytes.count >= 12
```

which accepts any file of at least 12 bytes, making every preceding JPEG/PNG/GIF/BMP/WebP
signature check redundant. A non-decodable thumbnail is accepted, stored as the project's
artwork, and then silently fails in `NSImage(contentsOf:)` in the sidebar.

Separately, `artwork(from:)` requires **exactly one** usable candidate, so if yt-dlp writes
two thumbnails the project silently gets no artwork at all.

## B9. Security-scoped access is released before the file is used — **Low**

`ContentView.swift:63-67` starts security-scoped access and `defer`s the stop within the
`.fileImporter` closure, but the file is actually read much later — by
`LocalAudioIngestClient.ingest` when Create Strata runs, and by `AVAudioFile` on every
replay. This works only because the app is not sandboxed (noted in
`StorageLocationPreferences.swift:6-10`). If sandboxing is ever enabled, local-file
separation breaks. The durable form is a security-scoped bookmark stored with the project.

## B10. `codesign --deep` and `--timestamp=none` in `build-dmg.sh` — **Low**

`scripts/build-dmg.sh:63`. `--deep` is deprecated by Apple and is known to mis-sign
nested content (sign inside-out instead); `--timestamp=none` produces a signature that stops
validating once the signing certificate expires. Fine for the stated personal-distribution
purpose, but both will bite if this ever moves to Developer ID + notarisation.

## B11. Delete unlinks files under an open playhead — **Low**

`SessionStore.deleteProject` (`:51`) removes the project directory and *then* calls
`newSession` (which stops playback). On macOS the open file descriptors keep the inodes
alive so audio keeps playing from unlinked data, but stopping playback before deleting is
the honest ordering.

## B12. Corrupted sessions vanish silently — **Low**

`StrataProjectPersistence.enumerateProjects` (`:221`) uses `try? load(projectID:)` and drops
anything that fails validation. A project with a corrupted `project.json`, a missing stem,
or a hash mismatch simply disappears from the Library with no explanation and no way to
investigate. Surfacing "1 session could not be opened" would be a small, kind addition.

---

# Part 3 — What is notably solid

Worth stating plainly, because the concurrency work here is better than most:

- **`InferenceWorkerClient`'s process-ownership model.** Monotonic generations,
  `invalidatedGenerations` to reject stale callbacks, `terminateOwnedSession` coalescing all
  termination requests for one exact `Process`/generation into a single retained task,
  and `finalizeCleanupAfterProvenDeath` refusing to declare cleanup complete until death is
  proven. The comment "There must never be two live worker processes owned by one client"
  is actually enforced, not just asserted.
- **`RuntimeReadinessChecker.captureVersionOutput`** is a textbook correct subprocess drain:
  concurrent readers, hard deadline, SIGTERM→SIGINT→SIGKILL escalation, and non-blocking
  final reads so a descendant holding the write end can't stall it. C1 is entirely about
  the other five call sites not using this.
- **`persistAssets`' stage → backup → commit → rollback** is a real transaction, and
  `restoreFromBackup` correctly distinguishes "restore the old file" from "remove a
  partially committed new file".
- **Path containment validation** in `loadValidated` — symlink-aware, canonical-shape,
  immediate-child-of-root, filename-exact, with distinct `symlinkEscapesProject` vs
  `pathEscapesProject` errors. Thorough.
- **`TrustedInferenceIdentity` as a native trust anchor.** The worker's `ready` metadata is
  treated as evidence to be cross-checked, never as trust. Model, checkpoint, backend and
  device are all validated against native constants.
- **Schedule-generation guards on every AVFoundation completion handler**, with an explicit
  comment about `player.stop()` synchronously invoking the previous handler on an arbitrary
  thread. That is the exact hazard, correctly handled.
- **Test coverage**: ~27k lines across 47 test files, including a state-machine suite, a
  shutdown-ordering suite, and a real-integration suite. The lifecycle invariants are tested,
  not just written down.

---

# Part 4 — Feature suggestions

Ordered by value per unit of effort.

## Tier 1 — finish what is already half-built

1. **Storage management** (pairs with B2). A Settings section showing Library / Scratch /
   Model sizes, a "Reclaim scratch space" button, and automatic GC of scratch runs older
   than N days at launch. Cheapest high-value item on this list; the paths are already
   centralised in `StorageLocationPreferences`.

2. **Real separation progress.** The worker already knows how far along it is —
   `_session.infer(verbose=True)` prints progress, currently only into the stderr tail. Add
   a `progress` NDJSON event type and a percentage/ETA in place of the static
   "Creating strata". This is the longest wait in the app and it currently has no feedback.

3. **Keep the engine warm, and queue jobs.** Model load is ~2 minutes and today every cancel
   throws it away (B6). Show an "Engine ready" indicator, keep the worker alive between
   jobs, and allow queuing several tracks. This converts the app's biggest cost from
   per-track into once-per-session.

4. **"Re-separate" on a Library row.** `SessionStore.owningYouTubeProject` already handles
   re-separation from a persisted `source/mixture.wav`, including dedupe and asset
   replacement — the plumbing exists but there is no button for it.

## Tier 2 — mixing

5. **dB-scale gain, plus per-stratum pan and a master fader.** A linear 0–100 % fader
   (`uiPercentToGain`) does not feel like audio; −∞…0 dB with a standard taper matches every
   DAW the target user knows. Pan is a single `AVAudioMixerNode` property away.

6. **Loop region / A-B repeat** on the shared timeline. `MultiStemAudioTransport.schedule`
   already does sample-accurate `scheduleSegment` from an arbitrary frame — looping is a
   small extension of it, and it is the single most-wanted feature for practising along.

7. **Persist mute and solo with the session.** Only gains survive a reopen today
   (`StrataProject.gains`). Mute/solo is the state users actually set up per song.

8. **Export the mix as heard.** One button that respects the current mute/solo/gain, instead
   of re-picking stems in a dialog. `StemPlaybackController.selectedStems` already computes
   exactly the right set.

9. **Waveform zoom.** `WaveformProvider` returns peak bins for a `targetCount`; adding a
   range + zoom level is a modest change and makes the six-lane view genuinely usable for
   finding a specific bar.

## Tier 3 — new capability

10. **Batch / folder separation** — point at a folder, queue everything, walk away. Natural
    once (3) exists.

11. **Drag stems out to Finder / Logic / Ableton.** `onDrag` with a file promise from each
    stratum row. Very cheap, and it is how this audience actually moves audio around.

12. **Tempo and key detection** on the mixture, plus an optional click track. Runs locally,
    fits the "practice with the parts" use case, and needs no new model.

13. **Keyboard shortcuts for the mixer** — `1`–`6` to mute, `⌥`-click or `⇧1`–`⇧6` to solo,
    space to play/pause. The mixer is mouse-only today.

14. **Loudness normalisation on export** (EBU R128 via ffmpeg `loudnorm`), so an isolated
    vocal doesn't come out 12 dB quieter than the mix.

## Tier 4 — polish

15. Dock progress indicator and a user notification when a long separation finishes.
16. "Reveal in Finder" for a Library project and for the last export.
17. Rename a Library session — the metadata editor exists, but the sidebar row is read-only.
18. Show duration and created-date on Library rows instead of just "YouTube" / "Local".
19. Surface unopenable sessions rather than hiding them (B12).

---

# Part 5 — Suggested order of work

1. **C1 + C2** — replace all five `liveRun` bodies and the `AudioProcessRunner` stdout pipe
   with the already-correct `captureVersionOutput` pattern. This removes every unbounded
   subprocess hang in the app, including the one that can brick first-run setup.
2. **B1** — the dead Save MP3 button. One-line class of fix, immediately visible.
3. **C3 + C12** — route `resetForNewSession`/`adoptCompleted` through the cleanup chain, and
   route the four silent cleanup-failure returns through
   `surfaceBlockedNewWorkAfterCleanupFailure`. Together these remove the "app does nothing"
   and "already running" surprises.
4. **B2 + Feature 1** — scratch GC plus the storage panel. Ship them as one change.
5. **C6** — move persist and reopen off the main actor with progress.
6. **C7** — observe `AVAudioEngineConfigurationChange`.
7. **B3 + B4** — checksum the remaining downloads; move FFmpeg/yt-dlp to minimum-version
   semantics and add an update action.
8. Everything else as convenient.
