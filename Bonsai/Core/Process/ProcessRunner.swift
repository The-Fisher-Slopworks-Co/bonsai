// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 The Fisher Slopworks Co

import Darwin
import Foundation

struct CommandResult: Sendable, Equatable {
    var status: Int32
    var output: String

    var succeeded: Bool { status == 0 }
}

enum ProcessRunner {
    struct LaunchError: Error {
        let errno: Int32
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        input: Data? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = try Spawned(
            executable: executable, arguments: arguments, directory: directory, environment: environment, input: input)
        return try await withTaskCancellationHandler {
            let output = await process.readAll(onLine: onLine)
            let status = await process.wait()
            try Task.checkCancellation()
            return CommandResult(status: status, output: output)
        } onCancel: {
            process.terminate()
        }
    }

    static func environment(_ overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("XCTest") || key.hasPrefix("DYLD_") || key == "__XPC_DYLD_LIBRARY_PATH"
        {
            env[key] = nil
        }
        env.merge(overrides) { _, new in new }
        return env
    }
}

private final class Spawned: @unchecked Sendable {
    let pid: pid_t
    private let readFD: Int32
    private let lock = NSLock()
    private var exited = false

    init(executable: String, arguments: [String], directory: URL?, environment: [String: String], input: Data?)
        throws
    {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ProcessRunner.LaunchError(errno: errno) }
        readFD = fds[0]
        let writeFD = fds[1]
        var inputFDs: [Int32] = [-1, -1]
        if input != nil && pipe(&inputFDs) != 0 {
            let error = errno
            close(readFD)
            close(writeFD)
            throw ProcessRunner.LaunchError(errno: error)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inputFDs[0], 0)
            posix_spawn_file_actions_addclose(&actions, inputFDs[0])
            posix_spawn_file_actions_addclose(&actions, inputFDs[1])
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        if let directory {
            posix_spawn_file_actions_addchdir(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attributes, &noMask)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let env = ProcessRunner.environment(environment)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for arg in argv { free(arg) }
            for entry in envp { free(entry) }
        }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(writeFD)
        if let input {
            close(inputFDs[0])
            Self.write(input, to: inputFDs[1])
        }
        guard rc == 0 else {
            close(readFD)
            throw ProcessRunner.LaunchError(errno: rc)
        }
        pid = child
    }

    private static func write(_ input: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            input.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    offset += n
                }
            }
            close(fd)
        }
    }

    func readAll(onLine: (@Sendable (String) -> Void)?) async -> String {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [readFD] in
                var data = Data()
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = read(readFD, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                    guard let onLine else { continue }
                    pending.append(buffer, count: n)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = pending[pending.startIndex..<newline]
                        onLine(String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\r", with: ""))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
                if let onLine, !pending.isEmpty {
                    onLine(String(decoding: pending, as: UTF8.self))
                }
                close(readFD)
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [pid] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                self.lock.withLock { self.exited = true }
                let code: Int32
                if status & 0x7F == 0 {
                    code = (status >> 8) & 0xFF
                } else {
                    code = 128 + (status & 0x7F)
                }
                continuation.resume(returning: code)
            }
        }
    }

    func terminate() {
        guard !lock.withLock({ exited }) else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [pid] in
            if !self.lock.withLock({ self.exited }) { kill(-pid, SIGKILL) }
        }
    }
}
