import Foundation

/// Where babel-ui lives and how to reach it.
///
/// Every setting is looked up in this order, so the app agrees with the `babel-ui` shell command:
///   1. the app's environment (`BABEL_UI_PORT=8799 open -n "Babel UI.app"` — handy for testing),
///   2. `defaults write local.babel-ui.mac <key> <value>`,
///   3. babel-ui's own `.env` file,
///   4. the same default babel-ui.sh uses (for the folder: the checkout the app was built from).
struct Config {
    /// The babel-ui checkout (server.py, static/, .venv/).
    let dir: URL
    let port: Int
    let python: URL
    let log: URL
    let downloads: URL

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Environment for server.py: ours (so BABEL_* settings given to the app reach it) plus the port.
    var serverEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["BABEL_UI_PORT"] = String(port)
        // Apps started from Finder or at login get a bare PATH; keep /usr/bin first (system ssh,
        // which reads the user's ~/.ssh/config the same way the shell does) and add Homebrew.
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    static func load() -> Config {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        func setting(_ envKey: String, _ defaultsKey: String, dotenv: [String: String] = [:]) -> String? {
            for value in [env[envKey], defaults.string(forKey: defaultsKey), dotenv[envKey]] {
                if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
            }
            return nil
        }
        func path(_ s: String) -> URL {
            URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }

        let builtFrom = Bundle.main.object(forInfoDictionaryKey: "BabelUIDir") as? String
        let dir = path(setting("BABEL_UI_DIR", "babelUIDir") ?? builtFrom ?? "~/babel-ui").standardizedFileURL
        let dotenv = readDotEnv(dir.appendingPathComponent(".env"))

        let port = setting("BABEL_UI_PORT", "port", dotenv: dotenv).flatMap(Int.init) ?? 8765
        let venvPython = dir.appendingPathComponent(".venv/bin/python")
        let python = setting("BABEL_UI_PYTHON", "python", dotenv: dotenv).map(path)
            ?? (FileManager.default.isExecutableFile(atPath: venvPython.path) ? venvPython
                : URL(fileURLWithPath: "/usr/bin/python3"))
        let log = setting("BABEL_UI_LOG", "logFile").map(path)
            ?? home.appendingPathComponent("Library/Logs/babel-ui.log")
        let downloads = setting("BABEL_UI_DOWNLOADS", "downloadsDir").map(path)
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads")

        return Config(dir: dir, port: port, python: python, log: log, downloads: downloads)
    }

    /// KEY=value lines, same rules as server.py: comments, blank lines and `export ` are ignored,
    /// one pair of surrounding quotes is stripped.
    private static func readDotEnv(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, let q = val.first, q == "\"" || q == "'", val.last == q {
                val = String(val.dropFirst().dropLast())
            }
            out[key] = val
        }
        return out
    }
}
