import AppKit
import SwiftUI

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RemoteModel()
    @AppStorage("controlStyle") private var style: ControlStyle = .touch
    @AppStorage("keepOnTop") private var keepOnTop = false

    var body: some Scene {
        Window("TV Remote", id: "remote") {
            RemoteView()
                .environmentObject(model)
                .background(WindowConfigurator(keepOnTop: keepOnTop))
                .background(OpenWindowCapture(appDelegate: appDelegate))
                .task {
                    appDelegate.model = model
                    KeyboardShortcuts.shared.install(model: model)
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested()
                    #endif
                    await model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Remote") {
                Button("Home") { model.press(.home) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Control Center") { model.press(.controlCenter) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Screen Saver") { model.press(.screensaver) }
                Button("Sleep / Wake") { model.togglePower() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Keyboard") { model.openKeyboard() }
                    .keyboardShortcut("k")
                Divider()
                Button(model.trackpadMode ? "Stop Using Trackpad as Remote" : "Use Trackpad as Remote") {
                    model.setTrackpadMode(!model.trackpadMode)
                }
                .keyboardShortcut("t")
                .disabled(!model.isConnected)
                Picker("Control Style", selection: $style) {
                    Text("Touch Surface").tag(ControlStyle.touch)
                    Text("D-Pad").tag(ControlStyle.dpad)
                }
                Toggle("Keep Window on Top", isOn: $keepOnTop)
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Search for Apple TVs") { model.rescan() }
                    .keyboardShortcut("r")
                Button("Forget This Apple TV") { model.forgetSelected() }
                    .disabled(model.selected?.paired != true)
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { KeyboardShortcuts.showHelp() }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: RemoteModel? {
        didSet { menuBar.model = model }
    }
    /// SwiftUI's openWindow action, captured from the window's environment so
    /// the menu bar can bring the remote back after it's been closed.
    var openRemote: (() -> Void)? {
        didSet { menuBar.openRemote = openRemote }
    }
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writes to a bridge that just exited shouldn't kill the app.
        signal(SIGPIPE, SIG_IGN)
        menuBar.install()
    }

    // Closing the window tucks the app into the menu bar instead of quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuBar.showRemote() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}

/// Reaches the hosting NSWindow for the bits SwiftUI doesn't expose.
private struct WindowConfigurator: NSViewRepresentable {
    let keepOnTop: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MenuBarController.remoteWindow = window
            window.level = keepOnTop ? .floating : .normal
            // Transparent around the header strip and the remote's rounded body.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = false
            window.collectionBehavior.insert(.fullScreenNone)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            // An empty compact toolbar makes the title bar a little taller, which
            // drops the traffic lights down in line with the device name row.
            if window.toolbar == nil {
                window.toolbar = NSToolbar(identifier: "remote")
                window.toolbarStyle = .unifiedCompact
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
        }
    }
}

private struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AppDelegate

    var body: some View {
        Color.clear.onAppear {
            appDelegate.openRemote = { openWindow(id: "remote") }
        }
    }
}
