import SwiftUI

/// "Enter the code shown on your TV" screen, styled after the iPhone's.
struct PairingView: View {
    @EnvironmentObject private var model: RemoteModel
    @State private var pin = ""
    @FocusState private var focused: Bool

    private let length = 4

    var body: some View {
        ZStack {
            Color(white: 0.07)

            VStack(spacing: 22) {
                Image(systemName: "appletv.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 4)

                VStack(spacing: 8) {
                    Text("Enter Code")
                        .font(.system(size: 20, weight: .bold))
                    Text("Enter the \(length)-digit code shown on\n\(model.selected?.name ?? "your Apple TV").")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                content
                    .frame(height: 110, alignment: .top)

                Button("Cancel", action: model.cancelPairing)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .onChange(of: model.pairing) {
            if case .enterPin = model.pairing {
                pin = ""
                focused = true
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pairing {
        case .starting, .verifying, nil:
            ProgressView().controlSize(.small).padding(.top, 20)
        case .enterPin(let error):
            VStack(spacing: 14) {
                digits
                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let error):
            VStack(spacing: 12) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: model.startPairing)
            }
        }
    }

    private func digitBox(_ index: Int) -> some View {
        let chars = Array(pin)
        let current = index == chars.count && focused
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return shape
            .fill(Color(white: 0.15))
            .overlay(shape.strokeBorder(Color.white.opacity(current ? 0.6 : 0.08), lineWidth: 1.5))
            .overlay(
                Text(index < chars.count ? String(chars[index]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            )
            .frame(width: 44, height: 56)
    }

    private var digits: some View {
        ZStack {
            // An invisible field captures typing; the boxes just display it.
            TextField("", text: $pin)
                .focused($focused)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .onChange(of: pin) {
                    let cleaned = String(pin.filter(\.isNumber).prefix(length))
                    if cleaned != pin { pin = cleaned }
                    if cleaned.count == length {
                        Task { await model.submitPin(cleaned) }
                    }
                }

            HStack(spacing: 9) {
                ForEach(0..<length, id: \.self) { i in
                    digitBox(i)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
    }
}
