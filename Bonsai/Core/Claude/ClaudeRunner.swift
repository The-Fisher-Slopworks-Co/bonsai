// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Foundation

struct ClaudeRequest: Sendable, Equatable {
    var executable: String
    var directory: URL
    var prompt: String
    var allowedTools: [String]
    var schema: String
    var resume: String?
}

struct ClaudeError: Error, Equatable {
    var message: String
}

protocol ClaudeRunning: Sendable {
    func run(_ request: ClaudeRequest, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeResult
}

struct LiveClaudeRunner: ClaudeRunning {
    var shell = "/bin/zsh"
    var extraArguments: [String] = []
    var startTimeout: Duration = .seconds(120)

    func arguments(_ request: ClaudeRequest) -> [String] {
        var args = [
            request.executable, "-p", request.prompt,
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--allowedTools", request.allowedTools.joined(separator: ","),
            "--json-schema", request.schema,
        ]
        if let resume = request.resume { args += ["--resume", resume] }
        return args + extraArguments
    }

    func run(_ request: ClaudeRequest, onEvent: @escaping @Sendable (ClaudeEvent) -> Void) async throws -> ClaudeResult
    {
        let parser = ClaudeStreamParser(cwd: request.directory.path)
        let box = ResultBox()
        let started = Signal()
        let process = Task {
            try await ProcessRunner.run(shell, ["-lc", "\"$0\" \"$@\""] + arguments(request), in: request.directory) {
                line in
                for event in parser.parse(line) {
                    if case .started = event { started.fire() }
                    if case .finished(let result) = event { box.set(result) }
                    onEvent(event)
                }
            }
        }
        let watchdog = Task {
            try await Task.sleep(for: startTimeout)
            if !started.isFired {
                box.timedOut()
                process.cancel()
            }
        }
        let output: CommandResult
        do {
            output = try await withTaskCancellationHandler {
                try await process.value
            } onCancel: {
                process.cancel()
            }
        } catch is CancellationError where box.didTimeOut {
            throw ClaudeError(message: "claude did not start in \(startTimeout.components.seconds) s")
        }
        watchdog.cancel()
        try Task.checkCancellation()
        guard let result = box.value else {
            let tail = output.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw ClaudeError(message: tail.isEmpty ? "claude exited with \(output.status)" : tail)
        }
        return result
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ClaudeResult?
    private var expired = false
    func set(_ value: ClaudeResult) { lock.withLock { result = value } }
    var value: ClaudeResult? { lock.withLock { result } }
    func timedOut() { lock.withLock { expired = true } }
    var didTimeOut: Bool { lock.withLock { expired } }
}
