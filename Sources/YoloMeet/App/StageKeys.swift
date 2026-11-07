import AppKit

/// Keys for the stage's effects (`frame.keys`), while YOLO-meet is the active app and no text field in the panel has
/// focus. Keys are read by position, named as on an AZERTY keyboard (Z Q S D are W A S D on QWERTY; 0 is the top row's
/// 0 without Shift, or the keypad's). Only these keys are taken (the others reach the panel as usual); unlike clicker
/// keys they are never read from other apps, where they would fire while typing in Meet's chat.
final class StageKeys {
    /// Key codes by position (ANSI key codes are the same on AZERTY Macs).
    private static let names: [UInt16: String] = [15: "r", 13: "z", 0: "q", 1: "s", 2: "d", 29: "0", 82: "0"]
    private var held: Set<String> = []
    private var pressed: Set<String> = []
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(event) ?? event
        }
        // Keys released in another app never come back up here.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.held = [] }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard !(NSApp.keyWindow?.firstResponder is NSTextView),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let key = Self.names[event.keyCode]
        else { return event }
        if event.type == .keyDown {
            if !event.isARepeat { pressed.insert(key) }
            held.insert(key)
        } else {
            held.remove(key)
        }
        return nil  // handled: no beep
    }

    /// The keys for this frame: held ones, and those pressed since the last call.
    func take() -> StageFrame.Keys {
        defer { pressed = [] }
        return StageFrame.Keys(held: held, pressed: pressed)
    }
}
