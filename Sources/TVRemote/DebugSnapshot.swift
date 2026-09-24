#if DEBUG
import AppKit

/// Debug builds only: `TVREMOTE_SNAPSHOT=/path/out.png` writes the window
/// (including the title bar buttons) to a PNG a few seconds after launch.
/// `TVREMOTE_DEMO=1` shows the connected layout without a real Apple TV.
enum DebugSnapshot {
    static var isDemo: Bool { ProcessInfo.processInfo.environment["TVREMOTE_DEMO"] == "1" }

    @MainActor
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["TVREMOTE_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["TVREMOTE_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let frameView = window.contentView?.superview else { return }
            let bounds = frameView.bounds
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            frameView.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
#endif
