import Foundation
import Observation

/// A one-line summary of the user's Slurm jobs for the menu-bar menu, from GET /api/queue
/// (the same request the panel itself polls; it never prompts, ssh runs with BatchMode).
@Observable
final class QueueMonitor {
    private(set) var summary: String?
    private(set) var detail: String?
    private(set) var updated: Date?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30   // the server allows its ssh command 20 s
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// Every `interval` seconds: re-check the server, then refresh the summary while it runs.
    func start(server: ServerManager, interval: Duration = .seconds(60)) {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await server.recheck()
                await self?.refresh(server: server)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Refresh now unless the last answer is fresh enough (used when the menu opens).
    func refreshIfStale(server: ServerManager, maxAge: TimeInterval = 20) {
        if let updated, Date().timeIntervalSince(updated) < maxAge { return }
        Task { await refresh(server: server) }
    }

    func refresh(server: ServerManager) async {
        guard server.phase == .running else {
            summary = nil
            detail = nil
            return
        }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let url = server.config.baseURL.appendingPathComponent("api/queue")
        do {
            let (data, _) = try await session.data(from: url)
            let reply = try JSONDecoder().decode(QueueReply.self, from: data)
            if let jobs = reply.jobs {
                let states = jobs.map { $0.state ?? "" }
                let running = states.filter { $0 == "RUNNING" }.count
                let pending = states.filter { $0 == "PENDING" }.count
                let other = states.count - running - pending
                if states.isEmpty {
                    summary = "Jobs: none in queue"
                } else {
                    var parts = ["\(running) running", "\(pending) pending"]
                    if other > 0 { parts.append("\(other) other") }
                    summary = "Jobs: " + parts.joined(separator: " · ")
                }
                detail = jobs.prefix(8).map { "\($0.id ?? "?")  \($0.name ?? "")  \($0.state ?? "")" }
                    .joined(separator: "\n")
            } else {
                summary = "Jobs: cluster not connected"
                detail = reply.error
            }
        } catch {
            summary = "Jobs: unavailable"
            detail = error.localizedDescription
        }
        updated = Date()
    }

    private struct QueueReply: Decodable {
        struct Job: Decodable {
            let id: String?
            let name: String?
            let state: String?
        }
        let jobs: [Job]?
        let error: String?
    }
}
