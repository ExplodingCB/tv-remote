import AppKit

/// Lets the Mac keyboard drive the TV while the remote window is focused.
@MainActor
final class KeyboardShortcuts {
    static let shared = KeyboardShortcuts()

    private var monitor: Any?
    private weak var model: RemoteModel?

    func install(model: RemoteModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors always run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, model.isConnected, model.pairing == nil else { return false }
        // Leave typing in text fields (keyboard panel, pairing code) alone.
        if event.window?.firstResponder is NSTextView { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 126: model.press(.up)
        case 125: model.press(.down)
        case 123: model.press(.left)
        case 124: model.press(.right)
        case 36, 76:  // return, enter
            if !event.isARepeat { model.press(.select) }
        case 53, 51:  // escape, delete
            model.press(.menu)
        case 49:  // space
            if !event.isARepeat { model.press(.playPause) }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "h", "t": model.press(.home)
            case "=", "+": model.press(.volumeUp)
            case "-", "_": model.press(.volumeDown)
            case "k": model.openKeyboard()
            case "c": model.press(.controlCenter)
            default: return false
            }
        }
        return true
    }

    static func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = """
        Arrow keys\tNavigate
        Return\t\tSelect
        Esc / Delete\tBack
        Space\t\tPlay / Pause
        H\t\tTV / Home
        C\t\tControl Center
        + / −\t\tVolume
        K\t\tKeyboard

        Click the touch area to select, drag or two-finger swipe to move, and click and hold for more options.
        """
        alert.runModal()
    }
}
