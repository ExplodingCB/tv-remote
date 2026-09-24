import AppKit
import ServiceManagement

/// The menu bar icon. Click it to show or hide the remote; right-click for
/// quick controls. While the remote window is closed or hidden the app lives
/// only up here, with no Dock icon.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static weak var remoteWindow: NSWindow?

    weak var model: RemoteModel?
    var openRemote: (() -> Void)?

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "appletvremote.gen1.fill", accessibilityDescription: "TV Remote")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "TV Remote"
        }
        menu.delegate = self
        statusItem = item

        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window === Self.remoteWindow else { return }
                self.model?.setTrackpadMode(false)
                self.moveToMenuBar()
            }
        }
        center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.moveToMenuBar() }
        }
    }

    private var remoteIsVisible: Bool {
        guard let window = Self.remoteWindow else { return false }
        return window.isVisible && !NSApp.isHidden
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil  // keep left-click as a plain toggle
        } else if remoteIsVisible && NSApp.isActive {
            hideRemote()
        } else {
            showRemote()
        }
    }

    func showRemote() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if let window = Self.remoteWindow, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openRemote?()
        }
        NSApp.activate()
    }

    func hideRemote() {
        Self.remoteWindow?.close()
    }

    private func moveToMenuBar() {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(remoteIsVisible ? "Hide Remote" : "Show Remote") { [weak self] in
            guard let self else { return }
            self.remoteIsVisible ? self.hideRemote() : self.showRemote()
        })
        menu.addItem(.separator())

        if let model {
            let status: String
            switch model.connection {
            case .connected: status = model.selected?.name ?? "Connected"
            case .connecting: status = "Connecting…"
            case .searching: status = "Searching…"
            default: status = "Not Connected"
            }
            let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let connected = model.isConnected
            menu.addItem(item("Play / Pause", enabled: connected) { model.press(.playPause) })
            menu.addItem(item("Home", enabled: connected) { model.press(.home) })
            menu.addItem(item("Sleep / Wake", enabled: connected) { model.togglePower() })
            menu.addItem(.separator())
        }

        let login = item("Launch at Login") { Self.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit TV Remote") { NSApp.terminate(nil) })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.runModal()
        }
    }

    private func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        item.isEnabled = enabled
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
