import Foundation
import Observation

/// Starts babel-ui's server.py when nothing answers on the port yet, and stops it again on quit —
/// but only a server this app started. A server started with the `babel-ui` shell command (or by an
/// earlier copy of this app) is left alone unless the user explicitly restarts it.
@Observable
final class ServerManager {
    enum Phase: Equatable {
        case checking
        case starting
        case running
        /// Something holds the port but doesn't answer HTTP (a frozen server).
        case unresponsive
        case stopped
        case failed(String)
    }

    private(set) var phase: Phase = .checking {
        didSet { if phase != oldValue { onChange?() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    let config: Config
    /// The server.py this app spawned; nil when we're using one that was already running.
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var busy = false

    var ownsServer: Bool { process?.isRunning == true }
    var ownedPID: Int32? { ownsServer ? process?.processIdentifier : nil }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 3
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init(config: Config) {
        self.config = config
    }

    // MARK: - Checking

    /// Is the panel answering? Asks for "/" (a static page), like babel-ui.sh does, so checking
    /// can never trigger an ssh login, and with a short timeout so a frozen server can't hang us.
    func answers() async -> Bool {
        do {
            let (_, response) = try await session.data(from: config.baseURL)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Re-check a server we think is running (it may have been stopped behind our back).
    func recheck() async {
        guard !busy, phase == .running || phase == .unresponsive || phase == .stopped else { return }
        if await answers() {
            phase = .running
        } else if !ownsServer {
            phase = await Self.listenerPIDs(port: config.port).isEmpty ? .stopped : .unresponsive
        }
    }

    // MARK: - Starting / stopping

    /// Use the server if one answers; otherwise start server.py — unless something else holds the
    /// port, which we report instead of touching.
    func ensureRunning() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await ensureRunningLocked()
    }

    private func ensureRunningLocked() async {
        phase = .checking
        if await answers() {
            phase = .running
            return
        }
        if !(await Self.listenerPIDs(port: config.port)).isEmpty {
            phase = .unresponsive
            return
        }
        phase = .starting
        do {
            try spawn()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        for _ in 0..<60 {   // up to ~15 s; the first start can be slow (imports, keychain)
            try? await Task.sleep(for: .milliseconds(250))
            guard let p = process, p.isRunning else {
                phase = .failed("server.py exited right away.\n\n" + logTail())
                return
            }
            if await answers() {
                phase = .running
                return
            }
        }
        phase = .failed("server.py didn't answer on port \(config.port) within 15 seconds.\n\n" + logTail())
    }

    /// Restart. A server we didn't start is only stopped when `includingExternal` is set (the user
    /// confirmed it); otherwise this just (re)starts ours.
    func restart(includingExternal: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if ownsServer {
            await stopOwned()
        } else if includingExternal {
            await Self.stopListeners(port: config.port)
        }
        await ensureRunningLocked()
    }

    /// SIGTERM the server.py we started (aiohttp shuts down cleanly and hangs up its terminals; the
    /// shared ssh ControlMaster is a separate background process and stays up), SIGKILL after 3 s.
    func stopOwned() async {
        guard let p = process, p.isRunning else { return }
        stopping = true
        defer { stopping = false }
        let pid = p.processIdentifier
        p.terminate()
        for _ in 0..<30 where p.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if p.isRunning {
            kill(pid, SIGKILL)
            p.waitUntilExit()
        }
        process = nil
        phase = .stopped
    }

    /// Same as stopOwned(), but blocking (≤ 3 s): for quitting, where awaiting from
    /// applicationShouldTerminate's nested run loop could deadlock the main queue.
    func stopOwnedNow() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        defer { stopping = false }
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
        }
        process = nil
        phase = .stopped
    }

    private func spawn() throws {
        let fm = FileManager.default
        let script = config.dir.appendingPathComponent("server.py")
        guard fm.fileExists(atPath: script.path) else {
            throw AppError("Can't find \(script.path).\n\nSet the babel-ui folder with:\n"
                           + "defaults write local.babel-ui.mac babelUIDir /path/to/babel-ui")
        }
        guard fm.isExecutableFile(atPath: config.python.path) else {
            throw AppError("Can't run \(config.python.path).\n\nRun install.sh in \(config.dir.path) first.")
        }

        try fm.createDirectory(at: config.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: config.log.path) {
            fm.createFile(atPath: config.log.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: config.log)
        try log.seekToEnd()
        log.write(Data("\n--- \(Date().formatted(.iso8601)) started by Babel UI.app (port \(config.port))\n".utf8))

        let p = Process()
        p.executableURL = config.python
        p.arguments = ["-u", "server.py"]
        p.currentDirectoryURL = config.dir
        p.environment = config.serverEnvironment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(proc, status: status) }
        }
        try p.run()
        try? log.close()   // the child has its own copy
        process = p
    }

    private func exited(_ p: Process, status: Int32) {
        guard p === process, !stopping else { return }
        process = nil
        if phase == .running {
            phase = .failed("server.py stopped unexpectedly (exit status \(status)).\n\n" + logTail())
        }
    }

    func logTail(lines: Int = 15) -> String {
        guard let data = try? Data(contentsOf: config.log) else { return "" }
        let text = String(decoding: data.suffix(16_000), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Port helpers (run off the main thread)

    /// PIDs listening on 127.0.0.1:port, via lsof (like babel-ui.sh).
    nonisolated static func listenerPIDs(port: Int) async -> [pid_t] {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-ti", "tcp:\(port)", "-sTCP:LISTEN"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { pid_t($0) }
        }.value
    }

    /// Stop whatever listens on the port: TERM, then KILL if it ignores that (as babel-ui-stop does,
    /// minus closing the ssh connection). Only called after the user confirmed it.
    nonisolated static func stopListeners(port: Int) async {
        let pids = await listenerPIDs(port: port)
        guard !pids.isEmpty else { return }
        pids.forEach { kill($0, SIGTERM) }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if await listenerPIDs(port: port).isEmpty { return }
        }
        await listenerPIDs(port: port).forEach { kill($0, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(300))
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
