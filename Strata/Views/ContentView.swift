import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var playbackController: PlaybackController
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController

    // Backward compat for preview / tests that use single arg: provide convenience init
    init(
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) {
        self.playbackController = playbackController
        self.inferenceController = inferenceController
        self.stemPlaybackController = stemPlaybackController
    }
    init(playbackController: PlaybackController, inferenceController: InferenceController) {
        self.init(
            playbackController: playbackController,
            inferenceController: inferenceController,
            stemPlaybackController: StemPlaybackController()
        )
    }
    init(controller: PlaybackController) {
        self.init(
            playbackController: controller,
            inferenceController: InferenceController(),
            stemPlaybackController: StemPlaybackController()
        )
    }

    @State private var showingImporter = false
    @State private var showingError = false
    @Environment(SessionStore.self) private var sessionStore: SessionStore?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                controller: playbackController,
                stemPlaybackController: stemPlaybackController,
                inferenceController: inferenceController,
                showingImporter: $showingImporter
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            MainWorkspaceView(
                controller: playbackController,
                showingImporter: $showingImporter,
                inferenceController: inferenceController,
                stemPlaybackController: stemPlaybackController
            )
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.0))
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, UTType(filenameExtension: "m4a")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                playbackController.load(url: url)
                inferenceController.clearLoadedYouTubeSource()
            case .failure(let error):
                playbackController.errorMessage = error.localizedDescription
            }
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackController.errorMessage != nil },
            set: { if !$0 { playbackController.errorMessage = nil } }
        )) {
            Button("OK") { playbackController.errorMessage = nil }
        } message: {
            if let msg = playbackController.errorMessage { Text(msg) }
        }
        .alert("Inference Error", isPresented: Binding(
            get: { inferenceController.errorMessage != nil && inferenceController.state != .failed("Cancelled") },
            set: { if !$0 { inferenceController.dismissErrorAlert() } }
        )) {
            Button("OK") { inferenceController.dismissErrorAlert() }
        } message: {
            if let msg = inferenceController.errorMessage { Text(msg) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let store = sessionStore {
                        store.newSession(playbackController: playbackController, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
                    } else {
                        showingImporter = true
                    }
                } label: { Label("New Session", systemImage: "plus") }.help("New Session").accessibilityLabel("New Session")
            }
        }
    }
}

// MARK: - Sidebar (YouTube-aware: reflects PlaybackController OR StemPlaybackController)

struct SidebarView: View {
    @Bindable var controller: PlaybackController
    @Bindable var stemPlaybackController: StemPlaybackController
    @Bindable var inferenceController: InferenceController
    @Binding var showingImporter: Bool
    @Environment(SessionStore.self) private var sessionStore: SessionStore?

    // Primary initializer (YouTube-aware)
    init(
        controller: PlaybackController,
        stemPlaybackController: StemPlaybackController,
        inferenceController: InferenceController,
        showingImporter: Binding<Bool>
    ) {
        self.controller = controller
        self.stemPlaybackController = stemPlaybackController
        self.inferenceController = inferenceController
        self._showingImporter = showingImporter
    }

    var effectiveHasFile: Bool {
        controller.hasFile || stemPlaybackController.hasStems
    }

    var effectiveTitle: String? {
        if controller.hasFile, let t = controller.title { return t }
        if stemPlaybackController.hasStems {
            if let t = stemPlaybackController.title, !t.isEmpty { return t }
            if let base = inferenceController.exportBaseName, !base.isEmpty { return base }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return editable }
        }
        return nil
    }

    var effectiveDuration: String {
        if controller.hasFile { return controller.formattedDuration }
        if stemPlaybackController.hasStems { return stemPlaybackController.formattedDuration }
        return controller.formattedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Library", systemImage: "music.note.list")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button {
                    if let store = sessionStore {
                        store.newSession(playbackController: controller, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
                    } else {
                        showingImporter = true
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help("New Session").accessibilityLabel("New Session")
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.15)
            if let store = sessionStore {
                if store.projects.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text("No sessions yet").font(.callout).foregroundStyle(.secondary)
                        Text("Create a Strata or add audio to begin.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 20)
                        Spacer()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.projects.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }), id: \.id) { project in
                                Button {
                                    do {
                                        try store.reopen(projectID: project.id, playbackController: controller, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
                                    } catch {
                                        // SessionStore.lastError is already set (bounded); presented via alert — no second error model.
                                    }
                                } label: {
                                    SidebarEntry(title: project.displayTitle, duration: project.source.kind == .youTube ? "YouTube" : "Local", isSelected: project.id == store.selectedProjectID)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(project.displayTitle)
                            }
                        }.padding(.horizontal, 8).padding(.top, 8)
                    }
                }
            } else {
                if effectiveHasFile, let title = effectiveTitle {
                    ScrollView { VStack(spacing: 6) { SidebarEntry(title: title, duration: effectiveDuration, isSelected: true).padding(.horizontal, 8).padding(.top, 8) } }
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text("No audio loaded").font(.callout).foregroundStyle(.secondary)
                        Text("Add a local audio file to begin.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 20)
                        Button { showingImporter = true } label: { Text("Add Audio").font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 6) }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).accessibilityLabel("Add Audio")
                        Spacer()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(sidebarDotColor).frame(width: 6, height: 6)
                Text(sidebarStatusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10).background(Color.primary.opacity(0.04)).overlay(Divider().opacity(0.1), alignment: .top)
                .help(sidebarStatusText)
                .accessibilityIdentifier("RuntimeReadinessStatus")
        }.background(Color(nsColor: .windowBackgroundColor))
        .alert("Session Error", isPresented: Binding(
            get: { sessionStore?.lastError != nil },
            set: { if !$0 { sessionStore?.lastError = nil } }
        )) {
            Button("OK") { sessionStore?.lastError = nil }
        } message: {
            if let msg = sessionStore?.lastError { Text(msg) }
        }
    }

    private var sidebarStatusText: String {
        guard let r = inferenceController.runtimeReadiness else { return "Checking setup…" }
        if !r.isWorkerReady { return "Setup needed" }
        return r.sidebarStatus
    }

    private var sidebarDotColor: Color {
        guard let r = inferenceController.runtimeReadiness else { return Color.orange.opacity(0.9) }
        if r.isSeparationReady { return Color.green.opacity(0.9) }
        if !r.ffmpegAvailable || !r.workerAvailable { return Color.red.opacity(0.9) }
        return Color.orange.opacity(0.9)
    }
}

struct SidebarEntry: View {
    let title: String
    let duration: String
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.22)).frame(width: 36, height: 36)
                Image(systemName: "waveform").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Text(duration).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 10).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)).overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1))
    }
}

// MARK: - Main Workspace

struct MainWorkspaceView: View {
    @Bindable var controller: PlaybackController
    @Binding var showingImporter: Bool
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController

    private var completedResult: SeparationResult? {
        guard case .completed = inferenceController.state else { return nil }
        return inferenceController.result
    }

    private var isCompletedState: Bool {
        completedResult != nil
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !isCompletedState {
                        // Selected-audio header
                        if inferenceController.isYouTubeSourceLoaded {
                            Color.clear.frame(height: 20)
                        } else if controller.hasFile {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(controller.title ?? "Untitled").font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(controller.formattedDuration).font(.caption).foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text("Original mix").font(.caption).foregroundStyle(.secondary)
                                    Text("·").foregroundStyle(.tertiary)
                                    Text("Local file").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 20).padding(.top, 16)
                            TransportCard(controller: controller).padding(.horizontal, 20)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Tracks").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 20).padding(.bottom, 6)
                                OriginalMixRow(controller: controller).padding(.horizontal, 20)
                            }
                        } else {
                            EmptyStateView(showingImporter: $showingImporter).frame(height: 260).padding(.top, 20)
                        }
                    }

                    // M3 Inference Bridge - unified local source (playbackController is single source)
                    InferenceCard(
                        inferenceController: inferenceController,
                        stemPlaybackController: stemPlaybackController,
                        playbackController: controller,
                        showingImporter: $showingImporter
                    ).padding(.horizontal, 20).padding(.bottom, isCompletedState ? 8 : 16)
                }
            }
        }
    }
}

// Fallback for preview-only call sites.
extension MainWorkspaceView {
    init(controller: PlaybackController, showingImporter: Binding<Bool>) {
        self.controller = controller
        self._showingImporter = showingImporter
        self.inferenceController = InferenceController()
        self.stemPlaybackController = StemPlaybackController()
    }
}

struct EmptyStateView: View {
    @Binding var showingImporter: Bool
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.06)).frame(width: 72, height: 72)
                Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(spacing: 8) {
                Text("No audio selected").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("Add a local audio file to play, pause, and seek through AVAudioEngine.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            Button { showingImporter = true } label: { Label("Add Audio", systemImage: "plus").font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).accessibilityLabel("Add Audio")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inference Card (M3 minimal — completed-state hierarchy)

struct InferenceCard: View {
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController
    @Bindable var playbackController: PlaybackController
    @Binding var showingImporter: Bool
    private let storagePreferences = StorageLocationPreferences()
    @AppStorage("mp3Quality") private var mp3Quality: MP3Quality = .highVBR
    @State private var youTubeURLString = ""
    @State private var exportErrorMessage: String?
    @State private var youTubeSliderValue: Double = 0
    @State private var isYouTubeDragging = false
    @State private var exportingFileName: String?
    @State private var savedFileName: String?
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    private var youTubeURLBinding: Binding<String> {
        Binding(
            get: { sessionStore?.draftYouTubeURLString ?? youTubeURLString },
            set: { newValue in
                if let store = sessionStore {
                    store.draftYouTubeURLString = newValue
                } else {
                    youTubeURLString = newValue
                }
            }
        )
    }
    private var isExporting: Bool { exportingFileName != nil }

    private var completedResult: SeparationResult? {
        guard case .completed = inferenceController.state else { return nil }
        return inferenceController.result
    }

    private var isCompletedState: Bool {
        completedResult != nil
    }

    private var hasLoadedYouTubeAudioFile: Bool {
        guard inferenceController.isYouTubeSourceLoaded,
              let audioURL = inferenceController.loadedYouTubeAudioURL,
              playbackController.hasFile else { return false }
        return FileManager.default.fileExists(atPath: audioURL.path)
    }

    // Unified initializer
    init(
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController,
        playbackController: PlaybackController,
        showingImporter: Binding<Bool>
    ) {
        self.inferenceController = inferenceController
        self.stemPlaybackController = stemPlaybackController
        self.playbackController = playbackController
        self._showingImporter = showingImporter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompletedState ? 8 : 10) {
            HStack {
                Label("Create Strata", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button {
                    chooseDefaultExportFolder()
                } label: {
                    Label("Export Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Choose the default folder shown by export save panels")
                .accessibilityIdentifier("ChooseDefaultExportFolder")
                if !shouldShowPhaseList && inferenceController.isSeparating {
                    ProgressView().scaleEffect(0.7).tint(.secondary)
                }
            }
            if !isCompletedState, inferenceController.runtimeReadiness?.isWorkerReady == true {
                Text("Separation runs locally on this Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let completedResult = completedResult {
                // 1) Compact source summary — replaces large YouTube/local cards
                compactSourceSummary

                // 2) Collapse creation progress -> compact success
                compactSuccessView

                // 3) Promoted Strata mixer — primary visible area
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stems — 6 validated").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if let errorMessage = stemPlaybackController.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    StrataStackView(
                        result: completedResult,
                        stemPlaybackController: stemPlaybackController,
                        inferenceController: inferenceController
                    )
                }.padding(.top, 2)

                // 4) Demoted metadata — below strata (collapsed by default, opt-in disclosure)
                if inferenceController.isEditableMetadataAvailable || (playbackController.hasFile && !inferenceController.isYouTubeSourceLoaded) {
                    EditableMetadataEditor(inferenceController: inferenceController, isCollapsible: true, isInitiallyExpanded: false)
                }

            } else if let readiness = inferenceController.runtimeReadiness, !readiness.isWorkerReady {
                InferenceSetupView(controller: inferenceController)
            } else if inferenceController.runtimeReadiness == nil {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8).tint(.secondary)
                    Text("Checking setup…").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 8).accessibilityIdentifier("CheckingSetupIndicator")
            } else {
                // Pre-completion workflow — preserve exactly as before

                // Unified local source — single selection via Add Audio
                if !inferenceController.isYouTubeSourceLoaded {
                    HStack(spacing: 10) {
                        if playbackController.hasFile, let title = playbackController.title {
                            Label(title, systemImage: "doc.fill").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let url = playbackController.sourceURL {
                                Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { showingImporter = true } label: {
                                Label("Change", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.medium))
                            }.buttonStyle(.bordered).tint(.secondary).disabled(inferenceController.isSeparating)
                        } else {
                            Text("No file selected — Add audio to separate").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button { showingImporter = true } label: {
                                Label("Add Audio", systemImage: "plus").font(.caption.weight(.medium))
                            }.buttonStyle(.bordered).tint(.secondary).disabled(inferenceController.isSeparating)
                        }
                    }
                }

                // YouTube source-first workflow
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Paste YouTube URL", text: youTubeURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(inferenceController.isSeparating)
                        .accessibilityLabel("YouTube URL")
                        .accessibilityIdentifier("YouTubeURLField")
                    HStack(spacing: 10) {
                        Button {
                            let trimmed = youTubeURLBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
                            inferenceController.loadYouTubeSource(youTubeURL: url)
                        } label: {
                            Label("Load source", systemImage: "arrow.down.circle").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                        .disabled(youTubeURLBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inferenceController.isSeparating || !inferenceController.isYouTubePreviewReady)
                        .accessibilityIdentifier("LoadYouTubeSourceButton")
                    }
                    if let r = inferenceController.runtimeReadiness, !r.isYouTubePreviewReady {
                        Text(r.sidebarStatus).font(.caption2).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("YouTubeReadinessHint")
                    } else if inferenceController.runtimeReadiness == nil {
                        Text("Checking setup…").font(.caption2).foregroundStyle(.tertiary)
                    }

                    if inferenceController.isYouTubeSourceLoaded {
                        let hasAudioFile = hasLoadedYouTubeAudioFile
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                youTubeArtworkView()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(youTubeDisplayTitle())
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(youTubeDisplayArtist())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let channel = youTubeDisplayChannel(), !channel.isEmpty {
                                        Text(channel)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    if let durationText = youTubeDisplayDuration() {
                                        Text(durationText)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }

                            // Playback controls: disabled when preview only (no audio file)
                            VStack(spacing: 8) {
                                HStack {
                                    Text(hasAudioFile ? playbackController.formattedTime(isYouTubeDragging ? youTubeSliderValue : playbackController.currentTime) : (youTubeDisplayDuration() ?? "--:--"))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    Slider(
                                        value: Binding(
                                            get: { isYouTubeDragging ? youTubeSliderValue : playbackController.currentTime },
                                            set: { youTubeSliderValue = $0 }
                                        ),
                                        in: 0...(playbackController.duration > 0 ? playbackController.duration : 1),
                                        onEditingChanged: { editing in
                                            isYouTubeDragging = editing
                                            if editing {
                                                youTubeSliderValue = playbackController.currentTime
                                            } else {
                                                playbackController.seek(to: youTubeSliderValue)
                                            }
                                        }
                                    )
                                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                                    .disabled(!hasAudioFile)
                                    .accessibilityLabel("Seek YouTube source")
                                    Text(hasAudioFile ? playbackController.formattedDuration : (youTubeDisplayDuration() ?? "--:--"))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .trailing)
                                }
                                HStack {
                                    Button {
                                        if playbackController.isPlaying { playbackController.pause() } else { playbackController.play() }
                                    } label: {
                                        Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 36, height: 36)
                                            .background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle())
                                            .shadow(color: Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.4), radius: 8, y: 2)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!hasAudioFile)
                                    .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")

                                    Spacer()

                                    HStack(spacing: 6) {
                                        Circle().fill(hasAudioFile && playbackController.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                        Text(hasAudioFile && playbackController.isPlaying ? "Playing" : (hasAudioFile ? "Paused" : "Preview only")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }

                            // Gated actions: deferred audio acquisition (audio-only)
                            HStack(spacing: 10) {
                                Button {
                                    if hasAudioFile {
                                        inferenceController.startSeparationFromLoadedYouTubeSource()
                                    } else {
                                        inferenceController.startSeparationFromLoadedPreview()
                                    }
                                } label: {
                                    Label("Create Strata", systemImage: "waveform").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                                .disabled(!inferenceController.isYouTubeSourceLoaded || inferenceController.isSeparating || !inferenceController.isYouTubeSeparationReady)
                                .accessibilityIdentifier("SeparateLoadedYouTubeButton")

                                Button {
                                    if hasAudioFile, let prep = inferenceController.prepareYouTubeMP3ExportFromLoadedSource() {
                                        exportYouTubeMP3(prep)
                                    } else {
                                        inferenceController.prepareYouTubeMP3ExportFromLoadedPreview()
                                    }
                                } label: {
                                    Label("Save MP3", systemImage: "square.and.arrow.down").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!inferenceController.isYouTubeSourceLoaded || inferenceController.isSeparating || !inferenceController.isYouTubeMp3Ready || isExporting)
                                .accessibilityIdentifier("SaveYouTubeMP3Button")
                            }
                            exportStatus(accessibilityIdentifier: "YouTubeExportStatus")
                            if let r = inferenceController.runtimeReadiness {
                                if !r.isYouTubeSeparationReady {
                                    Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                                } else if !r.isYouTubeMp3Ready {
                                    Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor), lineWidth: 1)))
                    }
                }

                // Start / Cancel — uses single local source via playbackController
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    if !inferenceController.isYouTubeSourceLoaded {
                        Button {
                            guard let url = playbackController.sourceURL else { return }
                            inferenceController.startSeparation(localFileURL: url)
                        } label: {
                            Label("Create Strata", systemImage: "waveform").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).disabled(!playbackController.hasFile || playbackController.sourceURL == nil || inferenceController.isSeparating || !inferenceController.isLocalSeparationReady)
                        .accessibilityIdentifier("LocalSeparateButton")
                        Button {
                            exportLocalMP3()
                        } label: {
                            Label("Save MP3", systemImage: "square.and.arrow.down").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!playbackController.hasFile || inferenceController.isSeparating || !inferenceController.isMp3ExportReady || isExporting)
                        .accessibilityIdentifier("SaveLocalMP3Button")
                    }

                    if inferenceController.isSeparating && inferenceController.creationPhase != .complete {
                        Button(role: .destructive) { inferenceController.cancel() } label: { Text("Cancel").font(.callout.weight(.medium)) }.buttonStyle(.bordered).tint(.red)
                            .accessibilityIdentifier("CancelSeparationButton")
                    }
                    Spacer(minLength: 0)
                    if !shouldShowPhaseList {
                        Text(statusText).font(.caption).foregroundStyle(statusColor)
                    }
                }
                if shouldShowPhaseList {
                    phaseList
                }
                if let r = inferenceController.runtimeReadiness, !r.isLocalSeparationReady, !inferenceController.isYouTubeSourceLoaded {
                    Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
                if !inferenceController.isYouTubeSourceLoaded {
                    exportStatus(accessibilityIdentifier: "LocalExportStatus")
                    if let r = inferenceController.runtimeReadiness, !r.isMp3ExportReady {
                        Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                }

                // Failure
                if case .failed(let msg) = inferenceController.state, msg != "Cancelled" {
                    Text(msg).font(.caption).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true).padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if inferenceController.isEditableMetadataAvailable || (playbackController.hasFile && !inferenceController.isYouTubeSourceLoaded) {
                    EditableMetadataEditor(inferenceController: inferenceController)
                }

            }
        }.padding(isCompletedState ? 10 : 12).background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.12)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.13), lineWidth: 1)))
            .onChange(of: inferenceController.result) { _, result in
                guard let result else { return }
                loadCompletedResult(result)
                if let store = sessionStore {
                    store.handleCompletedSeparation(result: result, playbackController: playbackController, inferenceController: inferenceController, stemPlaybackController: stemPlaybackController)
                }
            }
            .onChange(of: inferenceController.preparedYouTubeMP3Export) { _, preparation in
                guard let preparation else { return }
                exportYouTubeMP3(preparation)
            }
            .onChange(of: inferenceController.loadedYouTubeSource) { _, loaded in
                guard let loaded else { return }
                let display = inferenceController.exportBaseName ?? loaded.metadata?.exportBaseName ?? loaded.metadata?.title
                playbackController.load(url: loaded.audioURL, displayTitle: display)
                youTubeSliderValue = 0
            }
            .onChange(of: inferenceController.loadedYouTubePreview) { _, preview in
                guard preview != nil else { return }
                // Preview only: no audio to load into playbackController
                youTubeSliderValue = 0
            }
            .onChange(of: playbackController.currentTime) { _, newValue in
                if !isYouTubeDragging { youTubeSliderValue = newValue }
            }
            .onAppear { youTubeSliderValue = playbackController.currentTime }
            .alert("Export Failed", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK") { exportErrorMessage = nil }
            } message: {
                if let exportErrorMessage { Text(exportErrorMessage) }
            }
    }

    // MARK: - Compact completed-source summary

    @ViewBuilder
    private var compactSourceSummary: some View {
        if inferenceController.isYouTubeSourceLoaded {
            let hasAudioFile = hasLoadedYouTubeAudioFile
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    youTubeArtworkView(size: 36, cornerRadius: 6, symbolSize: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(youTubeDisplayTitle())
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(youTubeDisplayArtist())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let durationText = youTubeDisplayDuration() {
                                Text(durationText)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let channel = youTubeDisplayChannel(), !channel.isEmpty {
                                if youTubeDisplayDuration() != nil { Text("·").font(.caption2).foregroundStyle(.tertiary) }
                                Text(channel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    if hasAudioFile {
                        Button {
                            if playbackController.isPlaying { playbackController.pause() } else { playbackController.play() }
                        } label: {
                            Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasAudioFile)
                        .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")
                        .help(hasAudioFile && playbackController.isPlaying ? "Pause" : "Play")
                    }
                    Button {
                        if hasAudioFile, let prep = inferenceController.prepareYouTubeMP3ExportFromLoadedSource() {
                            exportYouTubeMP3(prep)
                        } else {
                            inferenceController.prepareYouTubeMP3ExportFromLoadedPreview()
                        }
                    } label: {
                        Label("Save MP3", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!inferenceController.isYouTubeSourceLoaded || inferenceController.isSeparating || !inferenceController.isYouTubeMp3Ready || isExporting)
                    .accessibilityIdentifier("SaveYouTubeMP3Button")
                }
                exportStatus(accessibilityIdentifier: "YouTubeExportStatus")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.09)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1)))
        } else {
            // Local compact summary
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)).frame(width: 36, height: 36)
                        Image(systemName: "waveform").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackController.title ?? inferenceController.exportBaseName ?? "Untitled")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(playbackController.formattedDuration)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let url = playbackController.sourceURL {
                                Text("·").font(.caption2).foregroundStyle(.tertiary)
                                Text(url.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else if let base = inferenceController.exportBaseName, !base.isEmpty {
                                Text("·").font(.caption2).foregroundStyle(.tertiary)
                                Text(base).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    if playbackController.hasFile {
                        Button {
                            if playbackController.isPlaying { playbackController.pause() } else { playbackController.play() }
                        } label: {
                            Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!playbackController.hasFile)
                        .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")
                    }
                    Button {
                        exportLocalMP3()
                    } label: {
                        Label("Save MP3", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!playbackController.hasFile || inferenceController.isSeparating || !inferenceController.isMp3ExportReady || isExporting)
                    .accessibilityIdentifier("SaveLocalMP3Button")
                }
                exportStatus(accessibilityIdentifier: "LocalExportStatus")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.09)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1)))
        }
    }

    private var compactSuccessView: some View {
        HStack(spacing: 6) {
            Text("✓ 6 strata created")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.88))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        )
        .accessibilityIdentifier("PhaseListCompact")
    }

    @ViewBuilder
    private func exportStatus(accessibilityIdentifier: String) -> some View {
        if let exportingFileName {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(.secondary)
                Text("Exporting \(exportingFileName)…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        } else if let savedFileName {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Saved \(savedFileName)").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    func loadCompletedResult(_ result: SeparationResult) {
        // Prefer already-available ingest metadata ("Snow Patrol - Run") over raw inputURL ("mixture")
        let displayName: String? = {
            if let base = inferenceController.exportBaseName, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return base
            }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return editable }
            return nil
        }()
        if let displayName {
            stemPlaybackController.load(result: result, displayName: displayName)
        } else {
            stemPlaybackController.load(result: result)
        }
    }

    private func chooseDefaultExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the default folder for future exports."
        let defaultDirectoryAccess = storagePreferences.resolvedExportDirectoryAccess()
        panel.directoryURL = storagePreferences.resolvedExportURL()

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let directoryURL = panel.url else { return }
                do {
                    try storagePreferences.setExportDirectory(directoryURL)
                } catch {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func export(_ artifact: StemArtifact, as format: StemExportFormat) {
        guard !isExporting else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultFilename(
            for: artifact.name,
            format: format,
            sourceBaseName: inferenceController.effectiveExportBaseName
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)
        let capturedQuality = mp3Quality

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                let dest = destinationURL
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.export(
                                artifact,
                                to: dest,
                                format: format,
                                metadata: metadata,
                                artworkURL: artworkURL,
                                mp3Quality: capturedQuality,
                                ffmpegURL: ffmpegURL
                            )
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func exportMix(
        _ artifacts: [StemArtifact],
        as format: StemExportFormat = .mp3
    ) {
        guard !isExporting else { return }
        guard artifacts.count >= 2 else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL
        let gains = stemPlaybackController.stemGains
        let capturedQuality = mp3Quality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultMixFilename(
            for: artifacts.map(\.name),
            format: format,
            sourceBaseName: inferenceController.effectiveExportBaseName
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                let dest = destinationURL
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMix(
                                artifacts,
                                to: dest,
                                gains: gains,
                                format: format,
                                metadata: metadata,
                                artworkURL: artworkURL,
                                mp3Quality: capturedQuality,
                                ffmpegURL: ffmpegURL
                            )
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func exportYouTubeMP3(_ preparation: YouTubeIngestResult) {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        let effectiveMetadata = inferenceController.effectiveYouTubeMetadata
        let filenameMetadata = effectiveMetadata?.exportBaseName == nil ? preparation.metadata : effectiveMetadata
        panel.nameFieldStringValue = StemExporter.defaultYouTubeMP3Filename(
            metadata: filenameMetadata
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)
        let capturedQuality = mp3Quality
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                let dest = destinationURL
                let effectiveArtwork = self.inferenceController.effectiveArtworkURL
                let capturedMetadata = effectiveMetadata
                let capturedPreparationAudioURL = preparation.audioURL
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMP3(
                                from: capturedPreparationAudioURL,
                                to: dest,
                                metadata: capturedMetadata,
                                artworkURL: effectiveArtwork,
                                mp3Quality: capturedQuality,
                                ffmpegURL: ffmpegURL
                            )
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func exportLocalMP3() {
        guard !isExporting else { return }
        guard let sourceURL = playbackController.sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        let effectiveMetadata = inferenceController.effectiveYouTubeMetadata
        panel.nameFieldStringValue = StemExporter.defaultLocalMP3Filename(
            metadata: effectiveMetadata,
            fallbackTitle: playbackController.title,
            fallbackURL: sourceURL
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)
        let capturedQuality = mp3Quality
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                let dest = destinationURL
                let effectiveArtwork = self.inferenceController.effectiveArtworkURL
                let capturedMetadata = effectiveMetadata
                let capturedSourceURL = sourceURL
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMP3(
                                from: capturedSourceURL,
                                to: dest,
                                metadata: capturedMetadata,
                                artworkURL: effectiveArtwork,
                                mp3Quality: capturedQuality,
                                ffmpegURL: ffmpegURL
                            )
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    // MARK: - YouTube source presentation helpers

    @ViewBuilder
    private func youTubeArtworkView(
        size: CGFloat = 64,
        cornerRadius: CGFloat = 8,
        symbolSize: CGFloat = 20
    ) -> some View {
        let effective = inferenceController.effectiveArtworkURL
        let previewArt = inferenceController.loadedYouTubePreview?.artworkURL
        let sourceArt = inferenceController.loadedYouTubeSource?.artworkURL
        let url: URL? = effective ?? previewArt ?? sourceArt
        Group {
            if let u = url, let nsImage = NSImage(contentsOf: u) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(0.08))
                    Image(systemName: "waveform").font(.system(size: symbolSize, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    @ViewBuilder
    private func youTubeArtworkView(for loaded: YouTubeIngestResult) -> some View {
        youTubeArtworkView()
    }

    @ViewBuilder
    private func youTubeArtworkView(for preview: YouTubePreviewResult) -> some View {
        youTubeArtworkView()
    }

    private func youTubeDisplayTitle() -> String {
        let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editable.isEmpty { return editable }
        if let t = inferenceController.loadedYouTubePreview?.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let t = inferenceController.loadedYouTubeSource?.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let base = inferenceController.exportBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty { return base }
        if let base = inferenceController.loadedYouTubePreview?.metadata?.exportBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty { return base }
        if let base = inferenceController.loadedYouTubeSource?.metadata?.exportBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty { return base }
        if let url = inferenceController.loadedYouTubeSource?.audioURL { return url.deletingPathExtension().lastPathComponent }
        if let url = inferenceController.loadedYouTubeURL { return url.lastPathComponent }
        return "Untitled"
    }

    private func youTubeDisplayTitle(for loaded: YouTubeIngestResult) -> String { youTubeDisplayTitle() }
    private func youTubeDisplayTitle(for preview: YouTubePreviewResult) -> String { youTubeDisplayTitle() }

    private func youTubeDisplayArtist() -> String {
        let editable = inferenceController.editableArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editable.isEmpty { return editable }
        if let a = inferenceController.loadedYouTubePreview?.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        if let a = inferenceController.loadedYouTubeSource?.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        return "Unknown Artist"
    }

    private func youTubeDisplayArtist(for loaded: YouTubeIngestResult) -> String { youTubeDisplayArtist() }
    private func youTubeDisplayArtist(for preview: YouTubePreviewResult) -> String { youTubeDisplayArtist() }

    private func youTubeDisplayChannel() -> String? {
        if let c = inferenceController.loadedChannelName?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        if let c = inferenceController.youTubeExportMetadata?.channel?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        if let c = inferenceController.loadedYouTubePreview?.metadata?.channel?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        if let c = inferenceController.loadedYouTubeSource?.metadata?.channel?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        return nil
    }

    private func youTubeDisplayChannel(for loaded: YouTubeIngestResult) -> String? { youTubeDisplayChannel() }
    private func youTubeDisplayChannel(for preview: YouTubePreviewResult) -> String? { youTubeDisplayChannel() }

    private func youTubeDisplayDuration() -> String? {
        guard let duration = inferenceController.loadedYouTubeDuration, duration > 0 else { return nil }
        return formattedYouTubeDuration(duration)
    }

    private func formattedYouTubeDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    // MARK: - Phase List (truthful progress)

    private var shouldShowPhaseList: Bool {
        // Show whenever controller has a phase. Hides when idle with no operation.
        // Completed is rendered as a compact success row; failed/cancelled hides.
        if case .failed = inferenceController.state { return false }
        if case .completed = inferenceController.state { return false }
        return inferenceController.creationPhase != nil
    }

    private var orderedPhases: [StrataCreationPhase] {
        if inferenceController.showDownloadingPhase {
            return [.downloadingAudio, .preparingAudio, .loadingModel, .creatingStrata, .complete]
        } else {
            return [.preparingAudio, .loadingModel, .creatingStrata, .complete]
        }
    }

    @ViewBuilder
    private var phaseList: some View {
        let phases = orderedPhases
        let current = inferenceController.creationPhase
        let currentIndex: Int = {
            guard let c = current, let idx = phases.firstIndex(of: c) else { return -1 }
            return idx
        }()

        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                let isCompleteFlow = current == .complete
                let rowState: PhaseRowState = {
                    if isCompleteFlow {
                        // All rows completed when flow is complete
                        return .completed
                    }
                    if index < currentIndex { return .completed }
                    if index == currentIndex { return .current }
                    return .future
                }()
                phaseRow(phase: phase, state: rowState)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        )
        .accessibilityIdentifier("PhaseList")
    }

    private enum PhaseRowState { case completed, current, future }

    @ViewBuilder
    private func phaseRow(phase: StrataCreationPhase, state: PhaseRowState) -> some View {
        HStack(spacing: 8) {
            Group {
                switch state {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.green)
                case .current:
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.secondary)
                        .frame(width: 12, height: 12)
                case .future:
                    Image(systemName: "circle")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .opacity(0.55)
                }
            }
            .frame(width: 12, height: 12)

            Text(phase.displayString)
                .font(state == .current ? .caption.weight(.semibold) : .caption2.weight(.medium))
                .foregroundStyle(colorForPhaseRow(state: state))
                .opacity(state == .future ? 0.42 : 1.0)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .opacity(state == .future ? 0.45 : 1.0)
        .accessibilityIdentifier("PhaseRow-\(phase.displayString)")
    }

    private func colorForPhaseRow(state: PhaseRowState) -> Color {
        switch state {
        case .completed: return Color.primary.opacity(0.85)
        case .current: return Color.primary
        case .future: return Color.secondary
        }
    }

    private var statusText: String {
        switch inferenceController.state {
        case .idle: return "Ready"
        case .loadingModel: return inferenceController.statusMessage
        case .separating: return "Separating…"
        case .completed: return "Complete"
        case .failed(let m): return m
        }
    }
    private var statusColor: Color {
        switch inferenceController.state {
        case .idle: return .secondary
        case .loadingModel, .separating: return Color(red: 0.56, green: 0.46, blue: 0.95)
        case .completed: return .green
        case .failed(let m) where m == "Cancelled": return .secondary
        case .failed: return .red
        }
    }
    private func icon(for stem: StemName) -> String {
        switch stem {
        case .vocals: return "mic.fill"
        case .drums: return "metronome.fill"
        case .bass: return "guitars.fill"
        case .guitar: return "guitars"
        case .piano: return "pianokeys"
        case .other: return "music.note"
        }
    }
}

struct EditableMetadataEditor: View {
    @Bindable var inferenceController: InferenceController
    let isCollapsible: Bool
    @State private var isExpanded: Bool

    init(inferenceController: InferenceController, isCollapsible: Bool = false, isInitiallyExpanded: Bool = true) {
        self.inferenceController = inferenceController
        self.isCollapsible = isCollapsible
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCollapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                        Text("MP3 Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                        Text(isExpanded ? "Edit ID3 metadata" : "ID3")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Text(isExpanded ? "Hide" : "Edit")
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ToggleMP3Tags")
                .help(isExpanded ? "Collapse MP3 Tags" : "Expand MP3 Tags")
            } else {
                Text("MP3 Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text("Edit ID3 metadata written into MP3 exports.").font(.caption2).foregroundStyle(.tertiary)
            }
            if !isCollapsible || isExpanded {
                if isCollapsible {
                    Text("Edit ID3 metadata written into MP3 exports.").font(.caption2).foregroundStyle(.tertiary)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Title").font(.caption2).foregroundStyle(.secondary)
                            TextField("Title", text: $inferenceController.editableTitle)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3TitleField")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Artist").font(.caption2).foregroundStyle(.secondary)
                            TextField("Artist", text: $inferenceController.editableArtist)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3ArtistField")
                        }
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Album").font(.caption2).foregroundStyle(.secondary)
                            TextField("Album", text: $inferenceController.editableAlbum)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3AlbumField")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Album Artist").font(.caption2).foregroundStyle(.secondary)
                            TextField("Album Artist", text: $inferenceController.editableAlbumArtist)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3AlbumArtistField")
                        }
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Year").font(.caption2).foregroundStyle(.secondary)
                            TextField("Year", text: $inferenceController.editableYear)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3YearField")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Genre").font(.caption2).foregroundStyle(.secondary)
                            TextField("Genre", text: $inferenceController.editableGenre)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3GenreField")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Track #").font(.caption2).foregroundStyle(.secondary)
                            TextField("Track #", text: $inferenceController.editableTrackNumber)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ID3TrackNumberField")
                        }
                    }
                }
                Divider().opacity(0.12)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Artwork").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(artworkStatusText).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let previewURL = inferenceController.effectiveArtworkURL {
                        HStack(spacing: 10) {
                            if let nsImage = NSImage(contentsOf: previewURL) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                            } else {
                                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)).frame(width: 56, height: 56).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                            }
                            Text(previewURL.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                    } else {
                        Text("No artwork — MP3 will have no cover image").font(.caption2).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 8) {
                        Button("Keep") { inferenceController.editableArtwork = .keep }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("ID3ArtworkKeep")
                            .disabled(!canKeep)
                        Button("Remove") { inferenceController.editableArtwork = .removed }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("ID3ArtworkRemove")
                        Button("Replace…") { chooseReplacementArtwork() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("ID3ArtworkReplace")
                    }
                }
            }
        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1)))
    }

    private var artworkStatusText: String {
        switch inferenceController.editableArtwork {
        case .keep: return inferenceController.effectiveArtworkURL != nil ? "Keep" : "Keep (none)"
        case .removed: return "Removed"
        case .replaced: return "Replaced"
        }
    }

    private var canKeep: Bool {
        if case .keep = inferenceController.editableArtwork { return false }
        return true
    }

    private func chooseReplacementArtwork() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            inferenceController.editableArtwork = .replaced(url)
        }
    }
}

struct StemAudibilityControls: View {
    @Bindable var stemPlaybackController: StemPlaybackController
    let stem: StemName

    var isMuted: Bool {
        stemPlaybackController.mutedStems.contains(stem)
    }

    var isSoloed: Bool {
        stemPlaybackController.soloedStems.contains(stem)
    }

    var muteBinding: Binding<Bool> {
        Binding(
            get: { isMuted },
            set: { stemPlaybackController.setMuted($0, for: stem) }
        )
    }

    var soloBinding: Binding<Bool> {
        Binding(
            get: { isSoloed },
            set: { stemPlaybackController.setSoloed($0, for: stem) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            // Mute: unmistakable filled/selected state when explicitly muted; preserve identity via waveform, not button color
            Button {
                stemPlaybackController.toggleMute(for: stem)
            } label: {
                Text("Mute")
                    .font(.caption.weight(isMuted ? .bold : .semibold))
                    .monospaced()
                    .frame(width: 52, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isMuted ? Color.red : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isMuted ? Color.red : Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .foregroundStyle(isMuted ? Color.white : Color.secondary)
                    .shadow(color: isMuted ? Color.red.opacity(0.32) : .clear, radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("StemMute-\(stem.rawValue)")
            .accessibilityLabel(isMuted ? "Unmute \(stem.rawValue)" : "Mute \(stem.rawValue)")
            .accessibilityAddTraits(isMuted ? .isSelected : [])
            .help(isMuted ? "Unmute \(stem.rawValue.capitalized)" : "Mute \(stem.rawValue.capitalized)")
            .animation(.easeInOut(duration: 0.15), value: isMuted)
            Button {
                stemPlaybackController.toggleSolo(for: stem)
            } label: {
                Text("Solo")
                    .font(.caption.weight(isSoloed ? .bold : .semibold))
                    .monospaced()
                    .frame(width: 52, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSoloed ? Color(red: 0.56, green: 0.46, blue: 0.95) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isSoloed ? Color(red: 0.56, green: 0.46, blue: 0.95) : Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .foregroundStyle(isSoloed ? Color.white : Color.secondary)
                    .shadow(color: isSoloed ? Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.32) : .clear, radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("StemSolo-\(stem.rawValue)")
            .accessibilityLabel(isSoloed ? "Unsolo \(stem.rawValue)" : "Solo \(stem.rawValue)")
            .accessibilityAddTraits(isSoloed ? .isSelected : [])
            .help(isSoloed ? "Unsolo \(stem.rawValue.capitalized)" : "Solo \(stem.rawValue.capitalized)")
            .animation(.easeInOut(duration: 0.15), value: isSoloed)
        }
        .disabled(!stemPlaybackController.hasStems)
    }
}

// MARK: - Transport Card

struct TransportCard: View {
    @Bindable var controller: PlaybackController
    @State private var sliderValue: Double = 0
    @State private var isDragging = false
    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 6) {
                HStack {
                    Text(controller.formattedTime(isDragging ? sliderValue : controller.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(get: { isDragging ? sliderValue : controller.currentTime }, set: { newVal in sliderValue = newVal }), in: 0...(controller.duration > 0 ? controller.duration : 1), onEditingChanged: { editing in isDragging = editing; if editing { sliderValue = controller.currentTime } else { controller.seek(to: sliderValue) } }).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).disabled(!controller.hasFile).accessibilityLabel("Seek")
                    Text(controller.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Button { if controller.isPlaying { controller.pause() } else { controller.play() } } label: { Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 36, height: 36).background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle()).shadow(color: Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.4), radius: 8, y: 2) }.buttonStyle(.plain).disabled(!controller.hasFile).accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(controller.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(controller.isPlaying ? "Playing" : "Paused").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.11)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.13), lineWidth: 1))).onChange(of: controller.currentTime) { _, newValue in if !isDragging { sliderValue = newValue } }.onAppear { sliderValue = controller.currentTime }
    }
}

// MARK: - Original Mix Row

struct OriginalMixRow: View {
    @Bindable var controller: PlaybackController
    var body: some View {
        HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.18)).frame(width: 32, height: 32); Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95)) }
            Text("Original mix").font(.callout.weight(.medium)).foregroundStyle(.primary)
            Spacer()
            Text(controller.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.11)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.13), lineWidth: 1)))
    }
}

#Preview {
    let fake = FakePreviewTransport()
    let ctrl = PlaybackController(transport: fake)
    let ic = InferenceController()
    let sc = StemPlaybackController()
    ContentView(playbackController: ctrl, inferenceController: ic, stemPlaybackController: sc).frame(width: 900, height: 600)
}

@MainActor
private final class FakePreviewTransport: AudioTransport {
    var duration: TimeInterval = 187
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 42
    var onCompletion: (() -> Void)?
    func load(url: URL) throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false }
}
