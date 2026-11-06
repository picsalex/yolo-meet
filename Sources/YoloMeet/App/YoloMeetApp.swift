import SwiftUI

@main
struct YoloMeetApp: App {
    @State private var model = AppModel()

    init() { Theme.registerFonts() }

    var body: some Scene {
        Window("YOLO-meet", id: "panel") {
            ControlPanel()
                .environment(model)
                .frame(minWidth: 380, minHeight: 640)
                .onDisappear { NSApp.terminate(nil) }
        }
        .defaultSize(width: 400, height: 820)
        .defaultPosition(.leading)
        .defaultLaunchBehavior(.presented)

        Window("YOLO-meet Stage", id: "stage") {
            StageView(model: model)
                .ignoresSafeArea()
                // The two windows are one app: closing either quits, so neither lingers on its own.
                .onDisappear { NSApp.terminate(nil) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .defaultPosition(.trailing)
        .defaultLaunchBehavior(.presented)
    }
}
