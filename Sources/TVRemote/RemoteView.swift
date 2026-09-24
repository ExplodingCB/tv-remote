import AppKit
import SwiftUI

/// Proportions follow the first-generation Siri Remote (the black one with
/// the white ring around MENU), scaled up to a comfortable on-screen size.
enum Theme {
    static let secondaryText = Color.white.opacity(0.55)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let body = Color(white: 0.055)
    static let glass = Color(white: 0.125)
    static let button = Color(white: 0.105)
    static let buttonPressed = Color(white: 0.19)

    static let width: CGFloat = 240
    static let stripHeight: CGFloat = 38  // matches the title bar, so the traffic lights sit centered in it
    static let stripGap: CGFloat = 8
    static let remoteHeight: CGFloat = 700
    static let height = stripHeight + stripGap + remoteHeight

    static let cornerRadius: CGFloat = 46
    static let glassHeight: CGFloat = 290
    static let buttonSize: CGFloat = 70
    static let leftColumn: CGFloat = width * 0.3
    static let rightColumn: CGFloat = width * 0.7
    static let firstRow: CGFloat = glassHeight + 62
    static let rowSpacing: CGFloat = 88

    static var bodyShape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    static var glassShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous)
    }
}

enum ControlStyle: String {
    case touch, dpad
}

struct RemoteView: View {
    @EnvironmentObject private var model: RemoteModel
    @State private var titlebarInset: CGFloat = 0

    var body: some View {
        VStack(spacing: Theme.stripGap) {
            HeaderStrip()
                .frame(height: Theme.stripHeight)

            ZStack(alignment: .top) {
                RemoteBody()

                switch model.setup {
                case .done:
                    RemoteControls()
                case .working(let status):
                    SetupView(status: status, error: nil)
                case .failed(let error):
                    SetupView(status: nil, error: error)
                }

                if model.pairing != nil {
                    PairingView()
                        .clipShape(Theme.bodyShape)
                        .transition(.opacity)
                }
            }
            .frame(width: Theme.width, height: Theme.remoteHeight)
        }
        .ignoresSafeArea(edges: .top)
        // The strip draws up under the transparent title bar, so only ask the
        // window for the height below it.
        .frame(width: Theme.width, height: Theme.height - titlebarInset, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
            // Measure once: resizing the window feeds back into this value.
            if titlebarInset == 0, inset > 0 { titlebarInset = inset.rounded() }
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: model.pairing != nil)
    }
}

// MARK: - Header strip

/// Simulator-style bar above the device: traffic lights, TV picker, power.
private struct HeaderStrip: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.panel.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)

            HStack(spacing: 4) {
                Spacer().frame(width: 70)  // traffic lights
                DeviceMenu()
                Spacer(minLength: 0)
                TrackpadModeButton()
                PowerButton()
            }
            .padding(.trailing, 6)
        }
    }
}

private struct DeviceMenu: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        Menu {
            if model.devices.isEmpty {
                Text(model.isScanning ? "Searching…" : "No Apple TVs Found")
            }
            ForEach(model.devices) { tv in
                Button {
                    Task { await model.choose(tv) }
                } label: {
                    if tv.id == model.selectedID {
                        Label(tv.name, systemImage: "checkmark")
                    } else {
                        Text(tv.name)
                    }
                }
            }
            Divider()
            Button(model.isScanning ? "Searching…" : "Search Again") { model.rescan() }
                .disabled(model.isScanning)
            if let tv = model.selected, tv.paired {
                Button("Forget \(tv.name)", role: .destructive) { model.forgetSelected() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.selected?.name ?? "Choose a TV")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 100, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StripButton: View {
    let symbol: String
    var active = false
    var dimmed = false
    let action: () -> Void

    var body: some View {
        PressArea(action: action, hold: nil, repeats: false) { pressed in
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(active ? Color.black : dimmed ? Theme.secondaryText : .white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(pressed ? 0.25 : 0.1)))
        }
        .frame(width: 26, height: 26)
    }
}

private struct TrackpadModeButton: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        StripButton(symbol: "hand.point.up.left.fill", active: model.trackpadMode, dimmed: !model.isConnected) {
            model.setTrackpadMode(!model.trackpadMode)
        }
        .help("Use the Mac trackpad as the remote's touchpad (⌘T)")
    }
}

private struct PowerButton: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        StripButton(symbol: "power", dimmed: model.isOn == false, action: model.togglePower)
            .help("Sleep / Wake")
    }
}

// MARK: - Remote body

private struct RemoteBody: View {
    var body: some View {
        let shape = Theme.bodyShape
        ZStack(alignment: .top) {
            // Matte black aluminum body.
            shape.fill(Theme.body)

            // Glass touch surface on top.
            Theme.glassShape
                .fill(Theme.glass)
                .frame(height: Theme.glassHeight)

            // Seam between glass and aluminum.
            Rectangle()
                .fill(Color.black)
                .frame(height: 1)
                .padding(.top, Theme.glassHeight)

            // Microphone slot.
            Capsule()
                .fill(Color.black)
                .frame(width: 16, height: 4)
                .padding(.top, 16)
        }
        .clipShape(shape)
        // A hairline edge keeps the black body visible on dark desktops.
        .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        // Empty areas of the body drag the window, like picking up the remote.
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    }
}

private struct RemoteControls: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ControlArea()
                .frame(width: Theme.width, height: Theme.glassHeight)
                .clipShape(Theme.glassShape)

            Group {
                SiriButton(ringed: true, action: { model.press(.menu) }, hold: { model.press(.menu, .hold) }) {
                    Text("MENU")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.4)
                }
                .help("Menu / Back (Esc). Hold for the Home screen")
                .position(x: Theme.leftColumn, y: Theme.firstRow)

                SiriButton(action: { model.press(.home) }, hold: { model.press(.controlCenter) }) {
                    Image(systemName: "tv").font(.system(size: 19, weight: .medium))
                }
                .help("TV / Home (H). Hold for Control Center")
                .position(x: Theme.rightColumn, y: Theme.firstRow)

                SiriButton(action: {
                    if model.showKeyboard { model.showKeyboard = false } else { model.openKeyboard() }
                }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(model.keyboardFocused ? Color.accentColor : .white)
                }
                .help("Type on your TV (K). Siri voice isn't available from a Mac")
                .position(x: Theme.leftColumn, y: Theme.firstRow + Theme.rowSpacing)

                SiriButton(action: { model.press(.playPause) }) {
                    Image(systemName: "playpause.fill").font(.system(size: 17, weight: .medium))
                }
                .help("Play / Pause (Space)")
                .position(x: Theme.leftColumn, y: Theme.firstRow + Theme.rowSpacing * 2)

                VolumeRocker()
                    .position(x: Theme.rightColumn, y: Theme.firstRow + Theme.rowSpacing * 1.5)
            }
            .opacity(model.isConnected ? 1 : 0.45)
        }
        .frame(width: Theme.width, height: Theme.remoteHeight, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if model.showKeyboard {
                KeyboardPanel()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: model.showKeyboard)
    }
}

// MARK: - Touch surface

private struct ControlArea: View {
    @EnvironmentObject private var model: RemoteModel
    @AppStorage("controlStyle") private var style: ControlStyle = .touch
    @State private var touchPoint: CGPoint?
    @State private var flash = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.isConnected {
                    if style == .dpad && !model.trackpadMode {
                        DPadRing(diameter: dpadDiameter(geo.size))
                    }
                    if let p = touchPoint {
                        Circle()
                            .fill(RadialGradient(colors: [.white.opacity(flash ? 0.22 : 0.12), .clear],
                                                 center: .center, startRadius: 0, endRadius: 55))
                            .frame(width: 110, height: 110)
                            .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                            .allowsHitTesting(false)
                    }
                    Touchpad(captureTrackpad: model.trackpadMode) { handle($0, size: geo.size) }
                    if model.trackpadMode {
                        TrackpadModeHint()
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 14)
                            .allowsHitTesting(false)
                    }
                } else {
                    StatusView()
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                }
            }
            .overlay {
                if model.trackpadMode {
                    Theme.glassShape
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu {
                Picker("Control Style", selection: $style) {
                    Text("Touch Surface").tag(ControlStyle.touch)
                    Text("D-Pad").tag(ControlStyle.dpad)
                }
                .pickerStyle(.inline)
            }
        }
    }

    private func dpadDiameter(_ size: CGSize) -> CGFloat { min(size.width, size.height) * 0.8 }

    private func handle(_ event: Touchpad.Event, size: CGSize) {
        switch event {
        case .touch(let phase, let point):
            model.touch(phase, at: point)
            withAnimation(.easeOut(duration: phase == .release ? 0.25 : 0.05)) {
                touchPoint = phase == .release ? nil : point
            }
        case .tap(let point):
            Haptics.tap()
            if !model.trackpadMode { pulse(at: point) }
            if style == .dpad, !model.trackpadMode, let direction = direction(at: point, size: size) {
                model.press(direction)
            } else {
                model.tap()
            }
        case .longPress(let point):
            Haptics.tap()
            if style == .dpad, !model.trackpadMode, let direction = direction(at: point, size: size) {
                model.press(direction, .hold)
            } else {
                model.press(.select, .hold)
            }
        case .step(let key):
            model.press(key)
        case .captureEnded:
            model.setTrackpadMode(false)
        }
    }

    private func pulse(at point: CGPoint) {
        touchPoint = point
        flash = true
        withAnimation(.easeOut(duration: 0.35)) {
            flash = false
            touchPoint = nil
        }
    }

    /// In D-pad mode the outer ring clicks in a direction; the middle selects.
    private func direction(at point: CGPoint, size: CGSize) -> RemoteKey? {
        let dx = (point.x - 0.5) * size.width
        let dy = (point.y - 0.5) * size.height
        guard hypot(dx, dy) > dpadDiameter(size) / 2 * 0.42 else { return nil }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        }
        return dy > 0 ? .down : .up
    }
}

private struct TrackpadModeHint: View {
    var body: some View {
        VStack(spacing: 3) {
            Text("Trackpad is the remote")
                .font(.system(size: 11.5, weight: .semibold))
            Text("Swipe to move · Click to select · ⌘T to exit")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }
}

private struct DPadRing: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
            Circle()
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                .frame(width: diameter * 0.42, height: diameter * 0.42)
            ForEach(0..<4) { i in
                Circle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 5, height: 5)
                    .offset(y: -diameter / 2 + 18)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StatusView: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        VStack(spacing: 12) {
            switch model.connection {
            case .searching:
                ProgressView().controlSize(.small)
                message("Looking for Apple TVs…", detail: nil)
            case .connecting:
                ProgressView().controlSize(.small)
                message("Connecting to \(model.selected?.name ?? "Apple TV")…", detail: nil)
            case .needsPairing:
                icon("appletv")
                message("Pair with \(model.selected?.name ?? "Apple TV")",
                        detail: "A code will appear on your TV.")
                pill("Pair", action: model.startPairing)
            case .failed(let error):
                icon("wifi.exclamationmark")
                message("Not Connected", detail: error)
                pill("Try Again", action: model.reconnect)
            case .idle, .connected:
                if model.devices.isEmpty {
                    icon("appletv")
                    message("No Apple TV Found",
                            detail: "Make sure your Apple TV is on and on the same network as this Mac.")
                    pill(model.isScanning ? "Searching…" : "Search Again", action: model.rescan)
                        .disabled(model.isScanning)
                } else {
                    icon("appletv")
                    message("Choose a TV", detail: "Pick your Apple TV from the menu above.")
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 28))
            .foregroundStyle(Theme.secondaryText)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

// MARK: - Buttons

/// The glossy black round buttons, with the optional white MENU ring.
private struct SiriButton<Label: View>: View {
    var ringed = false
    let action: () -> Void
    var hold: (() -> Void)?
    @ViewBuilder let label: () -> Label

    var body: some View {
        PressArea(action: action, hold: hold, repeats: false) { pressed in
            ZStack {
                if ringed {
                    Circle().strokeBorder(Color.white, lineWidth: 2.5)
                        .frame(width: Theme.buttonSize + 7, height: Theme.buttonSize + 7)
                }
                ButtonFace(pressed: pressed, shape: Circle())
                    .frame(width: Theme.buttonSize, height: Theme.buttonSize)
                label()
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Theme.buttonSize + 8, height: Theme.buttonSize + 8)
        .contentShape(Circle())
    }
}

private struct ButtonFace<S: Shape>: View {
    let pressed: Bool
    let shape: S

    var body: some View {
        // A clipped plain stroke: strokeBorder leaves a hairline past the ends
        // of fully rounded shapes.
        shape
            .fill(pressed ? Theme.buttonPressed : Theme.button)
            .overlay(shape.stroke(Color.white.opacity(0.06), lineWidth: 2))
            .clipShape(shape)
    }
}

private struct VolumeRocker: View {
    @EnvironmentObject private var model: RemoteModel

    var body: some View {
        ZStack {
            ButtonFace(pressed: false, shape: Capsule())
            VStack(spacing: 0) {
                RockerHalf(symbol: "plus") { model.press(.volumeUp) }
                    .help("Volume Up (+)")
                RockerHalf(symbol: "minus") { model.press(.volumeDown) }
                    .help("Volume Down (−)")
            }
            .clipShape(Capsule())
        }
        .frame(width: Theme.buttonSize, height: Theme.buttonSize + Theme.rowSpacing)
    }

    private struct RockerHalf: View {
        let symbol: String
        let action: () -> Void

        var body: some View {
            PressArea(action: action, hold: nil, repeats: true) { pressed in
                ZStack {
                    Rectangle().fill(pressed ? Theme.buttonPressed : Color.clear)
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// Mouse-down/up tracking with optional hold or auto-repeat, which a plain
/// SwiftUI Button can't do.
struct PressArea<Content: View>: View {
    let action: () -> Void
    let hold: (() -> Void)?
    let repeats: Bool
    @ViewBuilder let content: (Bool) -> Content

    @State private var pressed = false
    @State private var held = false
    @State private var timer: Timer?

    var body: some View {
        content(pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        held = false
                        Haptics.tap()
                        if repeats { action() }
                        startTimer()
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                        if !repeats && !held { action() }
                        pressed = false
                    }
            )
    }

    private func startTimer() {
        timer?.invalidate()
        if repeats {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                MainActor.assumeIsolated {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                        MainActor.assumeIsolated { action() }
                    }
                }
            }
        } else if let hold {
            timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { _ in
                MainActor.assumeIsolated {
                    held = true
                    Haptics.tap()
                    hold()
                }
            }
        }
    }
}

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Keyboard

private struct KeyboardPanel: View {
    @EnvironmentObject private var model: RemoteModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Type on TV", systemImage: "keyboard")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Done") { model.showKeyboard = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            TextField("Search or enter text", text: $model.keyboardText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
                .focused($focused)
                .onSubmit { model.showKeyboard = false }
                .onExitCommand { model.showKeyboard = false }
                .onChange(of: model.keyboardText) { model.keyboardTextChanged() }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 16, y: -2)
        )
        .onAppear { focused = true }
    }
}

// MARK: - Setup

private struct SetupView: View {
    @EnvironmentObject private var model: RemoteModel
    let status: String?
    let error: String?

    var body: some View {
        VStack(spacing: 12) {
            if let status {
                ProgressView().controlSize(.small)
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                Text("First launch only. This takes a few seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText.opacity(0.7))
            }
            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                Button("Try Again", action: model.retrySetup)
            }
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .frame(width: Theme.width, height: Theme.glassHeight)
    }
}
