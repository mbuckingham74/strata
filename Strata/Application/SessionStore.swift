import Foundation
import Observation

@MainActor @Observable final class SessionStore {
    // MARK: - Owned State

    var projects: [StrataProject] = []
    var selectedProjectID: String? = nil
    var draftYouTubeURLString: String = ""
    var lastError: String? = nil // bounded persistence/reopen error

    // Convenience aliases for bounded error state
    var persistenceError: String? { lastError }
    var reopenError: String? { lastError }

    private let persistence: StrataProjectPersistence
    private var lastPersistedJobId: String?

    // MARK: - Init / Load

    init(persistence: StrataProjectPersistence = StrataProjectPersistence()) {
        self.persistence = persistence
        loadProjects()
    }

    func loadProjects() {
        projects = persistence.enumerateProjects()
        lastError = nil
    }

    /// Resolve the persisted artwork file for a Library project, if present and on disk.
    /// Uses the persisted `artworkPath` only (relative to the project directory); no transient state,
    /// so the thumbnail survives reopen and relaunch.
    func artworkURL(for project: StrataProject) -> URL? {
        guard let artPath = project.artworkPath else { return nil }
        let candidate = persistence.projectDirectory(for: project.id).appendingPathComponent(artPath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func refresh() {
        loadProjects()
    }

    // MARK: - Delete

    /// Delete a Library project: removes its entire persisted directory via persistence and
    /// drops it from the Library immediately (ordering preserved via enumerateProjects).
    /// Deleting an unselected project leaves workspace state untouched; deleting the selected
    /// project reuses the single coherent `newSession` reset so no playback, inference, source,
    /// stem, or draft state keeps referencing deleted assets. Failure surfaces via bounded `lastError`.
    func deleteProject(
        id: String,
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) throws {
        let wasSelected = (selectedProjectID == id)
        do {
            try persistence.deleteProject(id: id)
        } catch {
            lastError = bounded(error.localizedDescription)
            throw error
        }
        projects = persistence.enumerateProjects()
        if wasSelected {
            newSession(playbackController: playbackController, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
        } else {
            lastError = nil
        }
    }

    // MARK: - Auto-persist wiring (Stage 2 defect fix)

    /// Smallest integration hook: called where `InferenceController.result` is transferred into stem playback.
    /// Persists exactly once for a newly completed separation, skips reopen, preserves handoff,
    /// and surfaces failure via bounded `lastError` without turning success into inference failure.
    func handleCompletedSeparation(
        result: SeparationResult,
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) {
        // Already persisted this job (e.g. reopen) — skip.
        if let last = lastPersistedJobId, last == result.jobId { return }
        // Reopened sessions live under Projects root; fresh separations live in scratch (Caches/Strata or temp).
        // A fresh re-separation of a persisted YouTube project reuses its persisted
        // mixture as input, so it also lives under Projects root — but it carries a
        // new jobId and must reach dedupe/replacement rather than being skipped.
        let projectsRoot = persistence.projectsRootURL().standardizedFileURL.path
        let inputPath = result.inputURL.standardizedFileURL.path
        if inputPath.hasPrefix(projectsRoot + "/") || inputPath == projectsRoot {
            if let owning = owningYouTubeProject(forInputURL: result.inputURL),
               persistedJobId(for: owning) != result.jobId {
                // Fall through to persistCompletedSeparation below.
            } else {
                lastPersistedJobId = result.jobId
                return
            }
        }
        do {
            try persistCompletedSeparation(
                result: result,
                playbackController: playbackController,
                inferenceController: inferenceController,
                stemPlaybackController: stemPlaybackController
            )
            lastPersistedJobId = result.jobId
        } catch {
            // persistCompletedSeparation already set bounded lastError; do not mutate inference state.
        }
    }

    // MARK: - Bounded error

    private func bounded(_ msg: String) -> String {
        String(msg.prefix(500))
    }

    private func isYouTubeLike(_ s: String) -> Bool {
        YouTubeCanonicalIdentity.isYouTubeURL(s)
    }

    /// The persisted YouTube project that owns an input file, if the input lives
    /// inside that project's own directory (e.g. a re-separation reusing the
    /// persisted `source/mixture.wav`). This is the reopened-project identity used
    /// when transient YouTube state (loaded URL, draft) is absent or stale.
    private func owningYouTubeProject(forInputURL inputURL: URL) -> StrataProject? {
        let root = persistence.projectsRootURL().standardizedFileURL.path
        let input = inputURL.standardizedFileURL.path
        guard input.hasPrefix(root + "/") else { return nil }
        let relative = String(input.dropFirst((root + "/").count))
        let id = relative.split(separator: "/").first.map(String.init) ?? ""
        guard (try? StrataProject.validateProjectID(id)) != nil else { return nil }
        let dir = persistence.projectDirectory(for: id).standardizedFileURL.path
        guard input == dir || input.hasPrefix(dir + "/") else { return nil }
        guard let project = try? persistence.load(projectID: id),
              project.source.kind == .youTube else { return nil }
        return project
    }

    /// The job currently persisted for a project, if its separation result loads.
    private func persistedJobId(for project: StrataProject) -> String? {
        try? persistence.loadSeparationResult(for: project).jobId
    }

    // MARK: - Persist completed separation

    /// Persist a completed separation using controller state.
    /// Derives source, displayTitle, gains, and artwork from the active controllers and result.
    /// Reuses Stage 1 persistence APIs; does not duplicate playback/inference responsibilities.
    @discardableResult
    func persistCompletedSeparation(
        result: SeparationResult,
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) throws -> StrataProject {
        // Derive gains from stem controller (clamped)
        var gainsMap: [StemName: Double] = [:]
        for stem in StemName.allCases {
            let g = Double(stemPlaybackController.gain(for: stem))
            gainsMap[stem] = min(max(g, 0.0), 1.0)
        }
        // Fallback to 1.0 if empty (should not happen as gain returns 1.0)
        if gainsMap.isEmpty {
            for stem in StemName.allCases { gainsMap[stem] = 1.0 }
        }

        // Derive displayTitle
        let editableTrimmed = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let editableCandidate: String? = editableTrimmed.isEmpty ? nil : inferenceController.editableTitle
        let inputName = result.inputURL.deletingPathExtension().lastPathComponent
        let candidate: String? = inferenceController.effectiveExportBaseName ?? editableCandidate ?? playbackController.title ?? (inputName.isEmpty ? nil : inputName)
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalDisplay = trimmed.isEmpty ? "Untitled" : trimmed

        // Derive source. The owning persisted YouTube project wins when the input
        // is its own asset (re-separation): the audio being separated determines
        // identity even if transient state is absent or the draft went stale.
        // Otherwise fall back to transient state, then to a local file.
        let draftTrimmed = draftYouTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let owning = owningYouTubeProject(forInputURL: result.inputURL)
        let newMetadata = inferenceController.effectiveYouTubeMetadata ?? inferenceController.youTubeExportMetadata
        let source: StrataProjectSource
        if let owning {
            let metadata = newMetadata ?? owning.source.metadata
            source = StrataProjectSource(kind: .youTube, locator: owning.source.locator, metadata: metadata)
        } else if let ytURL = inferenceController.loadedYouTubeURL {
            source = StrataProjectSource(kind: .youTube, locator: ytURL.absoluteString, metadata: newMetadata)
        } else if !draftTrimmed.isEmpty && isYouTubeLike(draftTrimmed) {
            source = StrataProjectSource(kind: .youTube, locator: draftTrimmed, metadata: newMetadata)
        } else if inferenceController.isYouTubeSourceLoaded, let url = inferenceController.loadedYouTubeURL {
            source = StrataProjectSource(kind: .youTube, locator: url.absoluteString, metadata: newMetadata)
        } else {
            // Local file
            let locator = playbackController.sourceURL?.path ?? result.inputURL.path
            let finalLocator = locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/tmp/unknown.wav" : locator
            source = StrataProjectSource(kind: .localFile, locator: finalLocator, metadata: nil)
        }

        let now = Date()
        // YouTube re-separation dedup: same video must update the existing row
        // (same project id, replaced assets) instead of creating a duplicate.
        // Local files keep current behavior (new row per completion).
        if source.kind == .youTube {
            let newKey = YouTubeCanonicalIdentity.dedupeKey(for: source.locator)
            let match = persistence.enumerateProjects().first(where: {
                $0.source.kind == .youTube
                    && YouTubeCanonicalIdentity.dedupeKey(for: $0.source.locator) == newKey
            })
            if let match {
                // Replacement preserves what the new separation does not supply:
                // persisted metadata (when controllers carry none), the artwork
                // reference (when no new file is supplied), and saved gains (when
                // the controller still holds untouched defaults). Fresh values win.
                let finalSource: StrataProjectSource
                if source.metadata != nil {
                    finalSource = source
                } else {
                    // Same video, no fresh metadata: keep the persisted metadata.
                    finalSource = StrataProjectSource(kind: .youTube, locator: source.locator, metadata: match.source.metadata)
                }
                let finalGains: [StemName: Double] =
                    gainsMap.values.allSatisfy({ $0 == 1.0 }) ? match.gains : gainsMap
                let carriedArtworkPath: String? = {
                    guard let p = match.artworkPath else { return nil }
                    let u = persistence.projectDirectory(for: match.id).appendingPathComponent(p)
                    return FileManager.default.fileExists(atPath: u.path) ? p : nil
                }()
                let updated: StrataProject
                do {
                    updated = try StrataProject(
                        schemaVersion: 1,
                        id: match.id,
                        createdAt: match.createdAt,
                        lastOpenedAt: now,
                        displayTitle: finalDisplay,
                        source: finalSource,
                        artworkPath: carriedArtworkPath,
                        gains: finalGains
                    )
                } catch {
                    lastError = bounded(error.localizedDescription)
                    throw error
                }
                let artwork = inferenceController.effectiveArtworkURL
                return try persist(project: updated, result: result, artworkSourceURL: artwork)
            }
        }
        let id = UUID().uuidString.lowercased()
        let project: StrataProject
        do {
            project = try StrataProject(
                schemaVersion: 1,
                id: id,
                createdAt: now,
                lastOpenedAt: now,
                displayTitle: finalDisplay,
                source: source,
                gains: gainsMap
            )
        } catch {
            lastError = bounded(error.localizedDescription)
            throw error
        }

        let artwork = inferenceController.effectiveArtworkURL
        return try persist(project: project, result: result, artworkSourceURL: artwork)
    }

    /// Low-level persist: saves an already-constructed project with result and artwork.
    /// Updates projects and selectedProjectID on success, sets bounded error on failure.
    @discardableResult
    func persist(project: StrataProject, result: SeparationResult, artworkSourceURL: URL?) throws -> StrataProject {
        do {
            try persistence.persistCompletedSeparation(project: project, result: result, artworkSourceURL: artworkSourceURL)
        } catch {
            lastError = bounded(error.localizedDescription)
            throw error
        }
        projects = persistence.enumerateProjects()
        selectedProjectID = project.id
        lastPersistedJobId = result.jobId
        lastError = nil
        return project
    }

    // MARK: - Reopen

    /// Reopen a saved session without ingesting, downloading, or separating again.
    /// Restores canonical source playback, completed separation state, metadata/artwork, and saved stem gains.
    func reopen(
        projectID: String,
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) throws {
        do {
            let project = try persistence.load(projectID: projectID)
            let result = try persistence.loadSeparationResult(for: project)
            let projectDir = persistence.projectDirectory(for: project.id)
            let artworkURL: URL? = {
                guard let artPath = project.artworkPath else { return nil }
                let candidate = projectDir.appendingPathComponent(artPath)
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }()

            // Restore canonical source playback
            playbackController.load(url: result.inputURL, displayTitle: project.displayTitle)

            // Restore inference state (completed)
            inferenceController.adoptCompleted(project: project, result: result, artworkURL: artworkURL)

            // Restore stems and saved gains
            stemPlaybackController.load(result: result, displayName: project.displayTitle)
            stemPlaybackController.applyProjectGains(project.gains)

            // Update selection and draft URL
            selectedProjectID = project.id
            if project.source.kind == .youTube {
                draftYouTubeURLString = project.source.locator
            } else {
                // Keep draft cleared for local? Or retain? Clear to avoid stale YouTube URL.
                // Spec says newSession clears draft, reopen may restore draft for YouTube.
                draftYouTubeURLString = project.source.locator
                if !isYouTubeLike(draftYouTubeURLString) {
                    // For local projects, draft should be empty to indicate not YouTube; but locator is file path, not URL.
                    // Keep draft empty for local to reflect not YouTube; alternatively keep locator but tests expect empty for local?
                    // We'll clear for local.
                    draftYouTubeURLString = ""
                }
            }

            // Update lastOpenedAt best-effort (affects ordering)
            // Handle save with bounded do/catch; don't erase persistence error unless timestamp save succeeds.
            var saveError: String?
            do {
                var updated = project
                updated.lastOpenedAt = Date()
                try persistence.save(updated)
            } catch {
                saveError = bounded(error.localizedDescription)
            }

            projects = persistence.enumerateProjects()
            lastPersistedJobId = result.jobId
            if let saveError {
                lastError = saveError
            } else {
                lastError = nil
            }
        } catch {
            lastError = bounded(error.localizedDescription)
            throw error
        }
    }

    /// Convenience reopen via StrataProject value.
    func reopen(
        project: StrataProject,
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) throws {
        try reopen(projectID: project.id, playbackController: playbackController, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
    }

    // MARK: - New Session

    /// One coherent operation that clears active source/inference/stem state and draft YouTube URL.
    func newSession(
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) {
        playbackController.resetForNewSession()
        inferenceController.resetForNewSession()
        stemPlaybackController.resetForNewSession()
        draftYouTubeURLString = ""
        selectedProjectID = nil
        lastPersistedJobId = nil
        lastError = nil
    }
}
