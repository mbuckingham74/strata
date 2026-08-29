import SwiftUI

@main
struct DemuxApp: App {
    @State private var controller: PlaybackController

    init() {
        let transport = AVAudioEngineTransport()
        let ctrl = PlaybackController(transport: transport)
        _controller = State(initialValue: ctrl)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
