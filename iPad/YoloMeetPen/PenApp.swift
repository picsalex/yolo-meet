import SwiftUI

/// yolo-meet pen: the iPad is a pad for the Apple Pencil, and what is drawn on it is drawn on yolo-meet's stage on
/// the Mac (PenLink). The pad stands for the stage: the pen's place on it is its place there.
@main
struct PenApp: App {
    @State private var model = PadModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PadScreen()
                .environment(model)
                .onChange(of: phase, initial: true) {
                    // The link only lives while the app is in front, and the screen stays on while it is.
                    if phase == .active { model.start() } else if phase == .background { model.stop() }
                    UIApplication.shared.isIdleTimerDisabled = phase == .active
                }
        }
    }
}
