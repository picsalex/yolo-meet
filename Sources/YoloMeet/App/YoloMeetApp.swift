import SwiftUI

@main
struct YoloMeetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("YOLO-meet", id: "panel") {
            ControlPanel()
                .environment(model)
                .frame(minWidth: 380, minHeight: 640)
        }
        .defaultSize(width: 400, height: 820)
        .defaultPosition(.leading)
        .defaultLaunchBehavior(.presented)

        Window("YOLO-meet Stage", id: "stage") {
            StageView(model: model).ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .defaultPosition(.trailing)
        .defaultLaunchBehavior(.presented)
    }
}
