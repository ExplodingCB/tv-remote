import Foundation

struct BridgeError: LocalizedError {
    var message: String
    var type: String?

    var errorDescription: String? { message }
    var isAuthentication: Bool { type == "AuthenticationError" }

    static let notRunning = BridgeError(message: "The remote service isn't running.")
    static let timedOut = BridgeError(message: "The Apple TV didn't respond.")
}

/// Runs `atv_bridge.py` and exchanges line-delimited JSON with it.
@MainActor
final class Bridge {
    typealias Message = [String: Any]

    var onEvent: ((Message) -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<Message, BridgeError>) -> Void] = [:]

    var isRunning: Bool { process?.isRunning == true }

    func start(python: URL, script: URL, environment: [String: String]) throws {
        stop()

        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = python
        process.arguments = ["-u", script.path]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout

        let logURL = PythonEnvironment.supportDirectory.appendingPathComponent("bridge.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            // DispatchQueue.main keeps chunks in order, which Task { @MainActor } doesn't promise.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === process else { return }
                    self.handleExit()
                }
            }
        }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        try? input?.close()
        input = nil
        if process.isRunning { process.terminate() }
        failAll(.notRunning)
    }

    /// Sends a command and calls `completion` with the reply. The command is
    /// written immediately, so calls reach the TV in the order they're made.
    func call(_ command: String, _ params: Message = [:], timeout: TimeInterval = 30,
              completion: ((Result<Message, BridgeError>) -> Void)? = nil) {
        guard isRunning else {
            completion?(.failure(.notRunning))
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = completion ?? { _ in }
        write(params.merging(["cmd": command, "id": id]) { $1 })

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending.removeValue(forKey: id)?(.failure(.timedOut))
            }
        }
    }

    @discardableResult
    func request(_ command: String, _ params: Message = [:], timeout: TimeInterval = 30) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            call(command, params, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    /// Fire-and-forget, for high-frequency input like touch movement.
    func post(_ command: String, _ params: Message = [:]) {
        guard isRunning else { return }
        write(params.merging(["cmd": command]) { $1 })
    }

    // MARK: - Private

    private func write(_ message: Message) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? Message else { continue }

            if let id = message["id"] as? Int {
                guard let completion = pending.removeValue(forKey: id) else { continue }
                if message["ok"] as? Bool == true {
                    completion(.success(message))
                } else {
                    completion(.failure(BridgeError(
                        message: message["error"] as? String ?? "Something went wrong.",
                        type: message["error_type"] as? String)))
                }
            } else if message["event"] != nil {
                onEvent?(message)
            }
        }
    }

    private func handleExit() {
        process = nil
        input = nil
        buffer.removeAll()
        failAll(.notRunning)
        onExit?()
    }

    private func failAll(_ error: BridgeError) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }
}
