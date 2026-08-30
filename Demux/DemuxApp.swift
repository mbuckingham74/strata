import SwiftUI

@main
struct DemuxApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) var appDelegate

    @State private var playbackController: PlaybackController
    @State private var inferenceController: InferenceController

    init() {
        let transport = AVAudioEngineTransport()
        let pc = PlaybackController(transport: transport)
        _playbackController = State(initialValue: pc)
        let ic = InferenceController()
        _inferenceController = State(initialValue: ic)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(playbackController: playbackController, inferenceController: inferenceController)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.inferenceController = inferenceController
                }
                .onDisappear {
                    // keep reference
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
