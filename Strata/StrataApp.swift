import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Settings per-invocation centering

private final class WindowIDView: NSView {
    let windowIdentifier: NSUserInterfaceItemIdentifier

    init(identifier: NSUserInterfaceItemIdentifier) {
        self.windowIdentifier = identifier
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = windowIdentifier
    }
}

private struct WindowIDAccessor: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> NSView {
        WindowIDView(identifier: identifier)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = identifier
    }
}

private enum StrataWindowID {
    static let main = NSUserInterfaceItemIdentifier("StrataMainWindow")
    static let settings = NSUserInterfaceItemIdentifier("StrataSettingsWindow")
}

@MainActor
private final class SettingsWindowCentering: NSObject {
    static let shared = SettingsWindowCentering()
    static let settingsSize = NSSize(width: 680, height: 720)

    private var observer: NSObjectProtocol?

    @MainActor func start() {
        guard observer == nil else { return }

        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.handle(window)
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler)
    }

    @MainActor private func handle(_ window: NSWindow) {
        guard window.identifier == StrataWindowID.settings else { return }
        center(window)
    }

    @MainActor private func findMainWindow(excluding settingsWindow: NSWindow?) -> NSWindow? {
        let windows = NSApplication.shared.windows
        if let w = windows.first(where: { $0.identifier == StrataWindowID.main }), w !== settingsWindow, w.isVisible {
            return w
        }
        if let m = NSApplication.shared.mainWindow, m !== settingsWindow, m.isVisible { return m }
        let candidates = windows.filter { $0 !== settingsWindow && $0.isVisible && $0.styleMask.contains(.titled) }
        return candidates.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }.first
    }

    @MainActor func center(_ settingsWindow: NSWindow) {
        let main = findMainWindow(excluding: settingsWindow)
        let screen = main?.screen ?? settingsWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let currentSize = settingsWindow.frame.size
        let settingsSize = NSSize(
            width: min(currentSize.width > 0 ? currentSize.width : Self.settingsSize.width, visible.width),
            height: min(currentSize.height > 0 ? currentSize.height : Self.settingsSize.height, visible.height)
        )

        let desiredOrigin: NSPoint
        if let main {
            let mf = main.frame
            desiredOrigin = NSPoint(
                x: mf.midX - settingsSize.width / 2,
                y: mf.midY - settingsSize.height / 2
            )
        } else {
            desiredOrigin = NSPoint(
                x: visible.midX - settingsSize.width / 2,
                y: visible.midY - settingsSize.height / 2
            )
        }

        let clampedX = max(visible.minX, min(desiredOrigin.x, visible.maxX - settingsSize.width))
        let clampedY = max(visible.minY, min(desiredOrigin.y, visible.maxY - settingsSize.height))
        let newFrame = NSRect(origin: CGPoint(x: clampedX, y: clampedY), size: settingsSize)

        // Never disturb the main window; only reposition Settings.
        if settingsWindow.frame != newFrame {
            settingsWindow.setFrame(newFrame, display: true)
        }
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct StrataApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) var appDelegate

    @AppStorage("appearance") private var appearance: AppAppearance = .system

    @State private var playbackController: PlaybackController
    @State private var inferenceController: InferenceController
    @State private var stemPlaybackController: StemPlaybackController

    init() {
        let transport = AVAudioEngineTransport()
        let pc = PlaybackController(transport: transport)
        _playbackController = State(initialValue: pc)
        let ic = InferenceController()
        _inferenceController = State(initialValue: ic)
        _stemPlaybackController = State(initialValue: StemPlaybackController())
        Task { @MainActor in SettingsWindowCentering.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                playbackController: playbackController,
                inferenceController: inferenceController,
                stemPlaybackController: stemPlaybackController
            )
                .background(WindowIDAccessor(identifier: StrataWindowID.main))
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear {
                    appDelegate.inferenceController = inferenceController
                }
                .task {
                    await inferenceController.refreshRuntimeReadiness()
                }
                .onDisappear {
                    // keep reference
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect
            let size = CGSize(
                width: min(visible.width, max(1200, visible.width * 0.85)),
                height: min(visible.height, max(760, visible.height * 0.85))
            )
            return WindowPlacement(size: size)
        }

        Settings {
            SettingsView()
        }
        .defaultSize(width: 680, height: 720)
        .windowResizability(.contentMinSize)
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect
            let defaultSize = CGSize(width: 680, height: 720)
            let size = CGSize(
                width: min(defaultSize.width, visible.width),
                height: min(defaultSize.height, visible.height)
            )
            let position = CGPoint(
                x: visible.origin.x + (visible.width - size.width) / 2,
                y: visible.origin.y + (visible.height - size.height) / 2
            )
            return WindowPlacement(position, size: size)
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("mp3Quality") private var mp3Quality: MP3Quality = .highVBR
    @State private var libraryPath: String = StorageLocationPreferences().resolvedLibraryURL().path
    @State private var scratchPath: String = StorageLocationPreferences().resolvedScratchRootURL().path
    @State private var exportPath: String = StorageLocationPreferences().resolvedExportURL().path
    @State private var locationError: String?

    private var storage: StorageLocationPreferences { StorageLocationPreferences() }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("MP3 Quality") {
                Picker("Quality", selection: $mp3Quality) {
                    ForEach(MP3Quality.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Applies to all MP3 exports. WAV is always lossless.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Locations") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(libraryPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(libraryPath)
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseLibrary() }.controlSize(.small)
                        Button("Reset") { resetLibrary() }.controlSize(.small)
                        Spacer()
                    }
                    Text("Scratch holds temporary work (M4Ingest, M3Separations, LocalIngest). New jobs use the current folder; existing data is not moved.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Scratch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(scratchPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(scratchPath)
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseScratch() }.controlSize(.small)
                        Button("Reset") { resetScratch() }.controlSize(.small)
                        Spacer()
                    }
                    Text("Applies to new separations and ingests only.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Export").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(exportPath).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(exportPath)
                    HStack(spacing: 8) {
                        Button("Choose…") { chooseExport() }.controlSize(.small)
                        Button("Reset") { resetExport() }.controlSize(.small)
                        Spacer()
                    }
                    Text("Save panels open here; you can still choose any destination.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)

                if let locationError {
                    Text(locationError).font(.caption).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 656)
        .padding(12)
        .background(WindowIDAccessor(identifier: StrataWindowID.settings))
        .onAppear { refreshPaths() }
    }

    private func refreshPaths() {
        libraryPath = storage.resolvedLibraryURL().path
        scratchPath = storage.resolvedScratchRootURL().path
        exportPath = storage.resolvedExportURL().path
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = storage.resolvedLibraryURL()
        panel.prompt = "Choose"
        panel.message = "Choose the Library folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try storage.setLibraryDirectory(url)
                locationError = nil
                refreshPaths()
            } catch {
                locationError = error.localizedDescription
            }
        }
    }

    private func chooseScratch() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = storage.resolvedScratchRootURL()
        panel.prompt = "Choose"
        panel.message = "Choose the Scratch folder (new work only)."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try storage.setScratchDirectory(url)
                locationError = nil
                refreshPaths()
            } catch {
                locationError = error.localizedDescription
            }
        }
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = storage.resolvedExportURL()
        panel.prompt = "Choose"
        panel.message = "Choose the default Export folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try storage.setExportDirectory(url)
                locationError = nil
                refreshPaths()
            } catch {
                locationError = error.localizedDescription
            }
        }
    }

    private func resetLibrary() {
        storage.resetLibraryDirectory()
        locationError = nil
        refreshPaths()
    }

    private func resetScratch() {
        storage.resetScratchDirectory()
        locationError = nil
        refreshPaths()
    }

    private func resetExport() {
        storage.resetExportDirectory()
        locationError = nil
        refreshPaths()
    }
}
