import AppKit
import ApplicationServices

/// Presentation clickers and Stream Deck send arrow / page keys, which move through the story: always while yolo-meet
/// is the active app, and, while enabled, also when another app (Google Meet) has focus. Watching other apps' keys
/// needs the Accessibility permission.
final class ClickerKeys {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? install() : uninstall()
        }
    }

    private let onStep: (Bool) -> Void
    private var local: Any?
    private var global: Any?
    private static let forward: Set<UInt16> = [124, 125, 121]  // →, ↓, page down
    private static let backward: Set<UInt16> = [123, 126, 116]  // ←, ↑, page up

    init(onStep: @escaping (Bool) -> Void) {
        self.onStep = onStep
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Leave keys to text fields in the panel.
            guard let self, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            handle(event)
            // A step key is used up: passed on, it would also move the panel's selection, or beep.
            return Self.forward.union(Self.backward).contains(event.keyCode) ? nil : event
        }
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    private func handle(_ event: NSEvent) {
        if Self.forward.contains(event.keyCode) { onStep(true) }
        if Self.backward.contains(event.keyCode) { onStep(false) }
    }

    /// Other apps' keys.
    private func install() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(options)
        global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func uninstall() {
        global.map(NSEvent.removeMonitor)
        global = nil
    }
}
