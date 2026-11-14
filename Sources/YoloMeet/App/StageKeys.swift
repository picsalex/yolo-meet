import AppKit

/// Keys for the stage's effects (`frame.keys`), while yolo-meet is the active app and no text field in the panel has
/// focus. Keys are read by position, named as on an AZERTY keyboard (Z Q S D are W A S D on QWERTY; 0 is the top row's
/// 0 without Shift, or the keypad's; "space" the space bar; "cmd" either Command key, held on its own; "h" also toggles the camera image, and "p", "c" and "delete" (backspace) are the drawing's: on or off, clear, undo; `StageView`). Only these keys are taken (the others reach the panel as usual); unlike clicker
/// keys they are never read from other apps, where they would fire while typing in Meet's chat.
final class StageKeys {
    /// Key codes by position (ANSI key codes are the same on AZERTY Macs).
    private static let names: [UInt16: String] = [15: "r", 13: "z", 0: "q", 1: "s", 2: "d", 29: "0", 82: "0", 49: "space", 4: "h", 35: "p", 8: "c", 51: "delete"]
    private var held: Set<String> = []
    private var pressed: Set<String> = []
    private var released: Set<String> = []
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event) ?? event
        }
        // Keys released in another app never come back up here.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.held = [] }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            // Command alone: with another modifier it's a shortcut. The event goes on (menus and shortcuts still work).
            let down = event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
                && !(NSApp.keyWindow?.firstResponder is NSTextView)
            if down, held.insert("cmd").inserted { pressed.insert("cmd") }
            if !down, held.remove("cmd") != nil { released.insert("cmd") }
            return event
        }
        guard !(NSApp.keyWindow?.firstResponder is NSTextView),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let key = Self.names[event.keyCode]
        else { return event }
        if event.type == .keyDown {
            if !event.isARepeat { pressed.insert(key) }
            held.insert(key)
        } else if held.remove(key) != nil {
            released.insert(key)
        }
        return nil  // handled: no beep
    }

    /// Whether a key is down now (e.g. for a mouse click in action mode, between frames).
    func isHeld(_ key: String) -> Bool { held.contains(key) }

    /// The keys for this frame: held ones, and those pressed or released since the last call.
    func take() -> StageFrame.Keys {
        defer { (pressed, released) = ([], []) }
        return StageFrame.Keys(held: held, pressed: pressed, released: released)
    }
}
