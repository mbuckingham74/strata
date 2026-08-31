import SwiftUI

@main
struct StrataApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) var appDelegate

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                playbackController: playbackController,
                inferenceController: inferenceController,
                stemPlaybackController: stemPlaybackController
            )
                .frame(minWidth: 900, minHeight: 600)
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
        .windowResizability(.contentSize)
    }
}
