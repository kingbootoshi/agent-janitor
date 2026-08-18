import Foundation

public struct LunaVerdict {
    public var keyId: String
    public var verdict: String
    public var reason: String
}

public enum Luna {
    public static var apiKey: String? {
        ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
    }

    public static func triage(flags: [FlagRecord], evidence: [String: String] = [:], model: String, done: @escaping ([LunaVerdict]) -> Void) {
        guard let key = apiKey else { return done([]) }
        let lines = flags.map { f in
            "id=\(f.keyId) rule=\(f.rule) sig=\(f.signature) project=\(f.project) age=\(f.ageSeconds)s footprint=\(f.footprint / 1_048_576)MB \(evidence[f.keyId] ?? "") cmd=\(f.command) reason=\(f.reason)"
        }.joined(separator: "\n")

        let system = """
        You triage flagged processes on a macOS AI-agent dev workstation. Coding agents spawn dev servers, shells, and helpers that outlive their sessions. Each line carries hard evidence: cpu30m (CPU percent over the last 30 minutes), tty (attached terminal), parent (alive or reparented to launchd), listeners and established (socket counts). Classify each flagged process:
        dead - orphaned leftover, safe to terminate: parent dead, no tty, near-zero cpu, no established connections, and the command is a scratch tool (http.server, one-shot ssh, stale dev server)
        active - legitimately in use: tty attached, or established connections, or meaningful cpu that matches real work
        ambiguous - evidence genuinely conflicts
        A process burning high cpu with a dead parent and no tty for days is a stuck loop - call it dead and say why. Commit to dead or active when the evidence lines up; reserve ambiguous for real conflicts. Never mark training or inference jobs dead. Report every id exactly once via the tool.
        """

        let tool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "report_verdicts",
                "description": "Report a triage verdict for every flagged process",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "verdicts": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "verdict": ["type": "string", "enum": ["dead", "active", "ambiguous"]],
                                    "reason": ["type": "string", "description": "one short line"]
                                ],
                                "required": ["id", "verdict", "reason"]
                            ]
                        ]
                    ],
                    "required": ["verdicts"]
                ]
            ]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": lines]
            ],
            "tools": [tool],
            "tool_choice": ["type": "function", "function": ["name": "report_verdicts"]]
        ]

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("https://github.com/kingbootoshi/agent-janitor", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("agent-janitor", forHTTPHeaderField: "X-Title")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]],
                  let fn = toolCalls.first?["function"] as? [String: Any],
                  let argsRaw = fn["arguments"] as? String,
                  let args = try? JSONSerialization.jsonObject(with: Data(argsRaw.utf8)) as? [String: Any],
                  let verdicts = args["verdicts"] as? [[String: Any]] else { return done([]) }
            done(verdicts.compactMap { v in
                guard let id = v["id"] as? String,
                      let verdict = v["verdict"] as? String else { return nil }
                return LunaVerdict(keyId: id, verdict: verdict, reason: v["reason"] as? String ?? "")
            })
        }.resume()
    }
}
