import Foundation

/// Minimal Ollama HTTP client with lifecycle management.
/// Can start/stop `ollama serve` on demand — kills it when done
/// so we don't leave a server running the user didn't ask for.
actor OllamaClient {
    static let shared = OllamaClient()

    private let baseURL = URL(string: "http://localhost:11434")!
    private let model = "qwen2.5-coder:3b"
    private let session: URLSession

    /// Process handle if WE started ollama (nil = it was already running or not started)
    private var serverProcess: Process?
    /// Whether we started the server (so we know to kill it)
    private var weStartedServer = false

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    // MARK: - Server Lifecycle

    /// Check if Ollama is already running (~50ms).
    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Ensure Ollama is running. Starts it if not. Returns true if ready.
    func ensureRunning() async -> Bool {
        // Already running?
        if await isAvailable() { return true }

        // Check if ollama binary exists
        let whichResult = try? await runCommand("/usr/bin/which", args: ["ollama"])
        let ollamaPath: String
        if let path = whichResult?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            ollamaPath = path
        } else {
            // Try common install locations
            let candidates = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                print("[OllamaClient] ollama not found")
                return false
            }
            ollamaPath = found
        }

        // Start ollama serve
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ollamaPath)
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            serverProcess = proc
            weStartedServer = true
            print("[OllamaClient] Started ollama serve (PID \(proc.processIdentifier))")
        } catch {
            print("[OllamaClient] Failed to start ollama: \(error)")
            return false
        }

        // Poll until ready (up to 8 seconds)
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            if await isAvailable() {
                print("[OllamaClient] Server ready")
                return true
            }
        }

        print("[OllamaClient] Server did not become ready in time")
        return false
    }

    /// Shutdown Ollama if WE started it. No-op if it was already running.
    func shutdownIfWeStarted() {
        guard weStartedServer, let proc = serverProcess, proc.isRunning else { return }

        // SIGTERM for graceful shutdown
        proc.terminate()
        print("[OllamaClient] Sent SIGTERM to ollama (PID \(proc.processIdentifier))")

        // Give it 3 seconds, then force kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak proc] in
            guard let proc = proc, proc.isRunning else { return }
            kill(proc.processIdentifier, SIGKILL)
            print("[OllamaClient] Force killed ollama")
        }

        serverProcess = nil
        weStartedServer = false
    }

    // MARK: - LLM Query

    /// Generate a short insight from process data. Returns nil on any failure.
    func summarizeProcesses(_ snapshot: ProcessSnapshot) async -> String? {
        let prompt = buildPrompt(from: snapshot)

        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": """
                    You are a concise macOS system monitor embedded in an app switcher. \
                    Given process resource data, identify and group where resources are being hogged. \
                    Name the top offenders by memory and CPU. No suggestions, no advice — just report \
                    what's using the most. Use process names the user would recognize. 2 sentences max, \
                    never exceed 180 characters total.
                    """
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "options": [
                "temperature": 0.3,
                "num_ctx": 2048,
                "num_predict": 80
            ] as [String: Any]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func buildPrompt(from snapshot: ProcessSnapshot) -> String {
        var lines: [String] = []
        lines.append("System: \(snapshot.cpuUsagePercent)% CPU, \(snapshot.memUsedGB)/\(snapshot.memTotalGB) RAM")
        if let temp = snapshot.tempC {
            lines.append("CPU temp: \(Int(temp))°C")
        }
        lines.append("")
        lines.append("Top processes (by memory):")
        for p in snapshot.processes.prefix(8) {
            lines.append("  \(p.name): \(p.memMB)MB, \(String(format: "%.1f", p.cpuPercent))% CPU")
        }
        return lines.joined(separator: "\n")
    }

    private func runCommand(_ path: String, args: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Lightweight snapshot struct

struct ProcessSnapshot: Sendable {
    struct Process: Sendable {
        let name: String
        let cpuPercent: Double
        let memMB: Int
    }

    let processes: [Process]
    let cpuUsagePercent: Int
    let memUsedGB: String
    let memTotalGB: String
    let tempC: Double?
}
