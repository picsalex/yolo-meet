import AppKit
import ApplicationServices

/// Presentation clickers and Stream Deck send arrow / page keys. While enabled, those keys move through the story even
/// when Google Meet has focus. Watching other apps' keys needs the Accessibility permission.
final class ClickerKeys {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? install() : uninstall()
        }
    }

    private let onStep: (Bool) -> Void
    private var monitors: [Any] = []
    private static let forward: Set<UInt16> = [124, 125, 121]  // →, ↓, page down
    private static let backward: Set<UInt16> = [123, 126, 116]  // ←, ↑, page up

    init(onStep: @escaping (Bool) -> Void) { self.onStep = onStep }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    private func install() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions(options)
        let handle = { [onStep] (event: NSEvent) in
            if Self.forward.contains(event.keyCode) { onStep(true) }
            if Self.backward.contains(event.keyCode) { onStep(false) }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in MainActor.assumeIsolated { handle(event) } },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Leave keys to text fields in the panel.
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                handle(event)
                // A step key is used up: passed on, it would also move the panel's selection, or beep.
                return Self.forward.union(Self.backward).contains(event.keyCode) ? nil : event
            },
        ].compactMap { $0 }
    }

    private func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
