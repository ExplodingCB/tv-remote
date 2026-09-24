import AppKit
import SwiftUI

struct AppleTV: Identifiable, Hashable {
    let id: String
    var name: String
    var model: String?
    var address: String?
    var paired: Bool
}

enum RemoteKey: String {
    case up, down, left, right, select, menu, home
    case playPause = "play_pause"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case controlCenter = "control_center"
    case screensaver
}

enum PressAction: String {
    case single, double, hold
}

enum TouchPhase: String {
    case press, hold, release
}

@MainActor
final class RemoteModel: ObservableObject {
    enum Setup: Equatable {
        case working(String)
        case failed(String)
        case done
    }

    enum Connection: Equatable {
        case idle
        case searching
        case connecting
        case connected
        case needsPairing
        case failed(String)
    }

    enum Pairing: Equatable {
        case starting
        case enterPin(error: String?)
        case verifying
        case failed(String)
    }

    @Published private(set) var setup: Setup = .working("Starting…")
    @Published private(set) var devices: [AppleTV] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var connection: Connection = .idle {
        didSet { if connection != .connected { trackpadMode = false } }
    }
    @Published private(set) var trackpadMode = false
    @Published private(set) var pairing: Pairing?
    @Published private(set) var isScanning = false
    @Published private(set) var isOn: Bool?
    @Published private(set) var keyboardFocused = false
    @Published var showKeyboard = false
    @Published var keyboardText = ""

    private let bridge = Bridge()
    private let discovery = Discovery()
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    private var rescanWork: DispatchWorkItem?
    private var suppressTextSync = false
    private var started = false

    var selected: AppleTV? { devices.first { $0.id == selectedID } }
    var isConnected: Bool { connection == .connected }

    init() {
        if let id = UserDefaults.standard.string(forKey: "lastDeviceID"),
           let name = UserDefaults.standard.string(forKey: "lastDeviceName") {
            let address = UserDefaults.standard.string(forKey: "lastDeviceAddress")
            devices = [AppleTV(id: id, name: name, address: address, paired: true)]
            selectedID = id
        }

        bridge.onEvent = { [weak self] in self?.handle(event: $0) }
        bridge.onExit = { [weak self] in self?.bridgeDidExit() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconnect(after: 2) }
        }
    }

    // MARK: - Startup

    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        if DebugSnapshot.isDemo {
            devices = [AppleTV(id: "demo", name: "Living Room", paired: true)]
            selectedID = "demo"
            connection = .connected
            isOn = true
            setup = .done
            if ProcessInfo.processInfo.environment["TVREMOTE_DEMO_PAIRING"] == "1" {
                connection = .needsPairing
                pairing = .enterPin(error: nil)
            }
            return
        }
        #endif

        if !(await PythonEnvironment.isReady()) {
            do {
                try await PythonEnvironment.prepare { [weak self] in self?.setup = .working($0) }
            } catch {
                setup = .failed(error.localizedDescription)
                started = false
                return
            }
        }
        guard launchBridge() else { return }
        setup = .done

        discovery.onChange = { [weak self] in
            guard let self, self.devices.isEmpty || !self.isConnected, !self.isScanning else { return }
            Task { await self.scan(autoconnect: !self.isConnected) }
        }
        discovery.start()

        if let selected, selected.paired {
            await connect()
            await scan(autoconnect: false)
        } else {
            await scan(autoconnect: true)
        }
    }

    func retrySetup() {
        setup = .working("Starting…")
        Task { await start() }
    }

    @discardableResult
    private func launchBridge() -> Bool {
        guard let script = PythonEnvironment.bridgeScript else {
            setup = .failed("atv_bridge.py is missing from the app.")
            return false
        }
        var env = PythonEnvironment.childEnvironment
        env["ATV_REMOTE_SUPPORT_DIR"] = PythonEnvironment.supportDirectory.path
        env["ATV_REMOTE_PAIRING_NAME"] = Host.current().localizedName ?? "Mac Remote"
        do {
            try bridge.start(python: PythonEnvironment.python, script: script, environment: env)
            return true
        } catch {
            setup = .failed("Couldn't start the remote service: \(error.localizedDescription)")
            return false
        }
    }

    private func bridgeDidExit() {
        guard setup == .done else { return }
        connection = .failed("The remote service stopped.")
        isOn = nil
        // Restart it; if it keeps dying the user can retry from the error state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.bridge.isRunning, self.launchBridge() else { return }
                self.scheduleReconnect(after: 0.5)
            }
        }
    }

    // MARK: - Discovery

    func rescan() {
        Task { await scan(autoconnect: !isConnected) }
    }

    func scan(autoconnect: Bool) async {
        guard !isScanning else { return }
        rescanWork?.cancel()
        isScanning = true
        if connection == .idle || (devices.isEmpty && connection != .connected) {
            connection = .searching
        }

        do {
            let hosts = await discovery.addresses()
            let reply = try await bridge.request("scan", ["timeout": hosts.isEmpty ? 4 : 3, "hosts": hosts], timeout: 20)
            let found = (reply["devices"] as? [Bridge.Message] ?? []).compactMap { raw -> AppleTV? in
                guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
                return AppleTV(id: id, name: name, model: raw["model"] as? String,
                               address: raw["address"] as? String, paired: raw["paired"] as? Bool ?? false)
            }
            // Keep the current TV listed even if it didn't answer this scan.
            var merged = found
            if let selected, !found.contains(where: { $0.id == selected.id }) {
                merged.insert(selected, at: 0)
            }
            devices = merged
        } catch {
            if connection == .searching { connection = .failed(error.localizedDescription) }
        }
        isScanning = false

        if connection == .searching { connection = .idle }
        if autoconnect, !isConnected {
            if let selected {
                await choose(selected)
            } else if devices.count == 1 {
                await choose(devices[0])
            }
        }
        if devices.isEmpty { scheduleRescan() }
    }

    /// Keep looking while nothing is found; the first scan can also come back
    /// empty while macOS is still asking for Local Network permission.
    private func scheduleRescan() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.devices.isEmpty, !self.isConnected else { return }
                Task { await self.scan(autoconnect: true) }
            }
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func choose(_ tv: AppleTV) async {
        if tv.id != selectedID {
            if isConnected { _ = try? await bridge.request("disconnect") }
            connection = .idle
            isOn = nil
            keyboardFocused = false
            showKeyboard = false
        }
        selectedID = tv.id
        if tv.paired {
            await connect()
        } else {
            connection = .needsPairing
            await beginPairing()
        }
    }

    // MARK: - Connection

    func connect() async {
        guard let tv = selected, tv.paired else { return }
        reconnectWork?.cancel()
        connection = .connecting
        do {
            let reply = try await bridge.request("connect", target(tv), timeout: 25)
            guard selectedID == tv.id else { return }
            isOn = reply["power"] as? Bool
            keyboardFocused = reply["keyboard"] as? Bool ?? false
            connection = .connected
            reconnectAttempts = 0
            remember(tv)
        } catch let error as BridgeError where error.isAuthentication {
            markPaired(tv.id, false)
            connection = .needsPairing
        } catch {
            connection = .failed(friendly(error))
        }
    }

    func reconnect() {
        reconnectAttempts = 0
        Task { await connect() }
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        guard selected?.paired == true, bridge.isRunning else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isConnected, self.connection != .connecting else { return }
                self.reconnectAttempts += 1
                Task { await self.connect() }
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func forgetSelected() {
        guard let tv = selected else { return }
        Task {
            _ = try? await bridge.request("disconnect")
            _ = try? await bridge.request("forget", ["device": tv.id])
            markPaired(tv.id, false)
            UserDefaults.standard.removeObject(forKey: "lastDeviceID")
            UserDefaults.standard.removeObject(forKey: "lastDeviceName")
            connection = .needsPairing
            isOn = nil
        }
    }

    private func target(_ tv: AppleTV) -> Bridge.Message {
        var params: Bridge.Message = ["device": tv.id]
        if let address = tv.address { params["host"] = address }
        return params
    }

    private func remember(_ tv: AppleTV) {
        UserDefaults.standard.set(tv.id, forKey: "lastDeviceID")
        UserDefaults.standard.set(tv.name, forKey: "lastDeviceName")
        UserDefaults.standard.set(tv.address, forKey: "lastDeviceAddress")
    }

    private func markPaired(_ id: String, _ paired: Bool) {
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].paired = paired
        }
    }

    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("not found") {
            return "Couldn't find \(selected?.name ?? "the Apple TV"). Make sure it's on the same network as this Mac."
        }
        return message
    }

    // MARK: - Pairing

    func beginPairing() async {
        guard let tv = selected else { return }
        pairing = .starting
        do {
            try await bridge.request("pair_begin", target(tv), timeout: 20)
            pairing = .enterPin(error: nil)
        } catch {
            pairing = .failed(error.localizedDescription)
        }
    }

    func submitPin(_ pin: String) async {
        guard let tv = selected else { return }
        pairing = .verifying
        do {
            try await bridge.request("pair_pin", ["pin": pin], timeout: 20)
            pairing = nil
            markPaired(tv.id, true)
            await connect()
        } catch {
            // The TV shows a fresh code for the next attempt.
            pairing = .starting
            do {
                try await bridge.request("pair_begin", target(tv), timeout: 20)
                pairing = .enterPin(error: "That code didn't work. Enter the new code shown on your TV.")
            } catch {
                pairing = .failed(error.localizedDescription)
            }
        }
    }

    func cancelPairing() {
        pairing = nil
        bridge.call("pair_cancel")
        if connection != .connected { connection = .needsPairing }
    }

    func startPairing() {
        Task { await beginPairing() }
    }

    // MARK: - Input

    /// Returns false (and tries to reconnect) when there's no live connection.
    private func ensureConnected() -> Bool {
        if isConnected { return true }
        switch connection {
        case .failed, .idle:
            if selected?.paired == true { Task { await connect() } }
        default:
            break
        }
        return false
    }

    func press(_ key: RemoteKey, _ action: PressAction = .single) {
        guard ensureConnected() else { return }
        bridge.call("key", ["key": key.rawValue, "action": action.rawValue], timeout: 10) { [weak self] in
            if case .failure(let error) = $0 { self?.commandFailed(error) }
        }
    }

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        guard isConnected else { return }
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 1000).rounded()) }
        bridge.post("touch", ["x": clamp(point.x), "y": clamp(point.y), "phase": phase.rawValue])
    }

    func tap() {
        guard ensureConnected() else { return }
        bridge.call("click", ["action": "single"], timeout: 10) { [weak self] in
            if case .failure(let error) = $0 { self?.commandFailed(error) }
        }
    }

    func togglePower() {
        guard ensureConnected() else { return }
        bridge.call("power", ["state": "toggle"], timeout: 15) { [weak self] result in
            switch result {
            case .success(let reply): self?.isOn = reply["on"] as? Bool
            case .failure(let error): self?.commandFailed(error)
            }
        }
    }

    private func commandFailed(_ error: BridgeError) {
        if error.message.contains("Not connected") || error.message == BridgeError.timedOut.message {
            connection = .failed("Lost connection to \(selected?.name ?? "the Apple TV").")
            scheduleReconnect(after: 0.3)
        }
    }

    func setTrackpadMode(_ on: Bool) {
        trackpadMode = on && isConnected
    }

    // MARK: - Keyboard

    func openKeyboard() {
        showKeyboard = true
        guard isConnected else { return }
        bridge.call("text", ["op": "get"], timeout: 5) { [weak self] result in
            guard let self, case .success(let reply) = result else { return }
            self.suppressTextSync = true
            self.keyboardText = reply["text"] as? String ?? ""
            self.suppressTextSync = false
        }
    }

    func keyboardTextChanged() {
        guard !suppressTextSync, isConnected else { return }
        bridge.call("text", ["op": "set", "text": keyboardText], timeout: 10)
    }

    // MARK: - Events

    private func handle(event: Bridge.Message) {
        switch event["event"] as? String {
        case "disconnected":
            guard isConnected else { return }
            connection = .failed("Lost connection to \(selected?.name ?? "the Apple TV").")
            keyboardFocused = false
            let delay = min(pow(2, Double(reconnectAttempts)), 30)
            scheduleReconnect(after: delay)
        case "power":
            isOn = event["on"] as? Bool
        case "keyboard":
            let focused = event["focused"] as? Bool ?? false
            keyboardFocused = focused
            if focused {
                openKeyboard()
            } else {
                showKeyboard = false
            }
        default:
            break
        }
    }

    func shutdown() {
        bridge.stop()
    }
}
