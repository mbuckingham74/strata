import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var controller: PlaybackController
    @State private var showingImporter = false
    @State private var showingError = false

    var body: some View {
        NavigationSplitView {
            SidebarView(controller: controller, showingImporter: $showingImporter)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            MainWorkspaceView(controller: controller, showingImporter: $showingImporter)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.0)) // placeholder to keep nav
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, UTType(filenameExtension: "m4a")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Access security-scoped if needed; fileImporter already grants.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                controller.load(url: url)
            case .failure(let error):
                controller.errorMessage = error.localizedDescription
            }
        }
        .alert("Playback Error", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            if let msg = controller.errorMessage {
                Text(msg)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Audio", systemImage: "plus")
                }
                .help("Add Audio")
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var controller: PlaybackController
    @Binding var showingImporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Library", systemImage: "music.note.list")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Add Audio")
                .accessibilityLabel("Add Audio")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            if controller.hasFile, let title = controller.title {
                ScrollView {
                    VStack(spacing: 6) {
                        SidebarEntry(
                            title: title,
                            duration: controller.formattedDuration,
                            isSelected: true
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No audio loaded")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Add a local audio file to begin.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    Button {
                        showingImporter = true
                    } label: {
                        Text("Add Audio")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                    .accessibilityLabel("Add Audio")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green.opacity(0.9))
                    .frame(width: 6, height: 6)
                Text("Engine ready · 100% local")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.03))
            .overlay(Divider().opacity(0.1), alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SidebarEntry: View {
    let title: String
    let duration: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.22))
                    .frame(width: 36, height: 36)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: - Main Workspace

struct MainWorkspaceView: View {
    @Bindable var controller: PlaybackController
    @Binding var showingImporter: Bool

    var body: some View {
        ZStack {
            // Dark main workspace
            Color(red: 0.09, green: 0.09, blue: 0.11)
                .ignoresSafeArea()

            if controller.hasFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Selected-audio header
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.title ?? "Untitled")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(controller.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("Original mix")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("Local file")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                        TransportCard(controller: controller)
                            .padding(.horizontal, 24)

                        // One Original mix row
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Tracks")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 8)

                            OriginalMixRow(controller: controller)
                                .padding(.horizontal, 24)
                        }
                        .padding(.bottom, 24)
                    }
                }
            } else {
                EmptyStateView(showingImporter: $showingImporter)
            }
        }
    }
}

struct EmptyStateView: View {
    @Binding var showingImporter: Bool

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 72, height: 72)
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(spacing: 8) {
                Text("No audio selected")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Add a local audio file to play, pause, and seek through AVAudioEngine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button {
                showingImporter = true
            } label: {
                Label("Add Audio", systemImage: "plus")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
            .accessibilityLabel("Add Audio")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transport Card

struct TransportCard: View {
    @Bindable var controller: PlaybackController
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 14) {
            // Progress slider with time labels
            VStack(spacing: 6) {
                HStack {
                    Text(controller.formattedTime(isDragging ? sliderValue : controller.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { isDragging ? sliderValue : controller.currentTime },
                            set: { newVal in
                                sliderValue = newVal
                                if isDragging {
                                    // Live scrub feedback without committing seek until end? But spec wants seek on commit.
                                }
                            }
                        ),
                        in: 0...(controller.duration > 0 ? controller.duration : 1),
                        onEditingChanged: { editing in
                            isDragging = editing
                            if editing {
                                sliderValue = controller.currentTime
                            } else {
                                controller.seek(to: sliderValue)
                            }
                        }
                    )
                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                    .disabled(!controller.hasFile)
                    .accessibilityLabel("Seek")

                    Text(controller.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            HStack {
                Button {
                    if controller.isPlaying {
                        controller.pause()
                    } else {
                        controller.play()
                    }
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle())
                        .shadow(color: Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.4), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(!controller.hasFile)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                Spacer()

                // Subtle status
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isPlaying ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(controller.isPlaying ? "Playing" : "Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .onChange(of: controller.currentTime) { _, newValue in
            if !isDragging {
                sliderValue = newValue
            }
        }
        .onAppear {
            sliderValue = controller.currentTime
        }
    }
}

// MARK: - Original Mix Row

struct OriginalMixRow: View {
    @Bindable var controller: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            Text("Original mix")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Text(controller.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            // No mute/solo/export — intentionally minimal
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

#Preview {
    let fake = FakePreviewTransport()
    let ctrl = PlaybackController(transport: fake)
    ContentView(controller: ctrl)
        .frame(width: 900, height: 600)
}

// Lightweight preview fake to satisfy preview without needing real file.
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
