import Foundation

/// Owns the private Python environment that runs pyatv, the library that speaks
/// Apple TV's Companion protocol. It lives in Application Support so the app
/// bundle itself stays small.
enum PythonEnvironment {
    static let pyatvRequirement = "pyatv~=0.18.0"

    static let supportDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TV Remote", isDirectory: true)

    static var venvDirectory: URL { supportDirectory.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venvDirectory.appendingPathComponent("bin/python3") }

    static var bridgeScript: URL? {
        if let url = Bundle.main.url(forResource: "atv_bridge", withExtension: "py") {
            return url
        }
        // Running unbundled via `swift run`: use the script from the source tree.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/atv_bridge.py")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    enum SetupError: LocalizedError {
        case noPython
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .noPython:
                return "Python 3.10 or newer is required. Install it with “brew install python” or “brew install uv”, then relaunch."
            case .commandFailed(let output):
                return "Setting up the remote service failed.\n\n" + output
            }
        }
    }

    static func isReady() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return false }
        return await run(python, ["-c", "import pyatv"]).status == 0
    }

    static func prepare(progress: @MainActor @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: venvDirectory)

        if let uv = firstExecutable(uvCandidates) {
            await progress("Creating Python environment…")
            try await check(run(uv, ["venv", "--python", "3.13", venvDirectory.path]))
            await progress("Installing Apple TV support…")
            try await check(run(uv, ["pip", "install", "--python", python.path, pyatvRequirement]))
        } else if let system = await suitablePython() {
            await progress("Creating Python environment…")
            try await check(run(system, ["-m", "venv", venvDirectory.path]))
            await progress("Installing Apple TV support…")
            try await check(run(python, ["-m", "pip", "install", "--disable-pip-version-check", "-q", pyatvRequirement]))
        } else {
            throw SetupError.noPython
        }
    }

    // MARK: - Helpers

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static var uvCandidates: [String] {
        ["\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
    }

    private static let pythonCandidates = [
        "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3",
    ]

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func suitablePython() async -> URL? {
        for path in pythonCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if await run(url, ["-c", "import sys; sys.exit(sys.version_info < (3, 10))"]).status == 0 {
                return url
            }
        }
        return nil
    }

    private static func check(_ result: (status: Int32, output: String)) throws {
        guard result.status == 0 else {
            throw SetupError.commandFailed(String(result.output.suffix(600)))
        }
    }

    /// GUI apps get a minimal PATH, so tools are always run by absolute path
    /// with the usual locations added for anything they spawn themselves.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    static func run(_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = childEnvironment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            // Drain output while it runs so a chatty installer can't fill the pipe and stall.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
