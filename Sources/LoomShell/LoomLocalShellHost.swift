//
//  LoomLocalShellHost.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// macOS host runtime that executes shell sessions behind a local PTY.
public struct LoomLocalShellHost: LoomShellHost {
    public init() {}

    public func startSession(request: LoomShellSessionRequest) async throws -> any LoomShellHostedSession {
#if os(macOS)
        try LoomLocalPTYHostedSession(request: request)
#else
        throw LoomShellError.unsupported("PTY hosting is only available on macOS.")
#endif
    }
}

#if os(macOS)
import CLoomShellSupport
import Darwin
import Dispatch

private final class LoomLocalPTYHostedSession: LoomShellHostedSession, @unchecked Sendable {
    let events: AsyncStream<LoomShellEvent>

    private let emitter: LoomShellEventEmitter
    private let childProcessID: pid_t
    private let sessionProcessGroupID: pid_t
    private let masterFileDescriptor: Int32
    private let processSource: any DispatchSourceProcess
    private let readSource: any DispatchSourceRead
    private let stateLock = NSLock()
    private var didClose = false
    private var didReapChild = false

    init(request: LoomShellSessionRequest) throws {
        emitter = LoomShellEventEmitter()
        events = emitter.stream

        let queue = DispatchQueue(label: "com.loom.shell.local-pty")
        var windowSize = winsize(
            ws_row: UInt16(clamping: request.rows),
            ws_col: UInt16(clamping: request.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let spawned = try Self.spawnShell(
            request: request,
            initialWindowSize: &windowSize
        )

        do {
            try Self.setNonBlocking(spawned.masterFileDescriptor)
        } catch {
            Self.forceTerminateProcessGroup(spawned.processGroupID)
            Darwin.close(spawned.masterFileDescriptor)
            _ = waitpid(spawned.pid, nil, 0)
            throw error
        }

        childProcessID = spawned.pid
        sessionProcessGroupID = spawned.processGroupID
        masterFileDescriptor = spawned.masterFileDescriptor
        processSource = DispatchSource.makeProcessSource(
            identifier: childProcessID,
            eventMask: .exit,
            queue: queue
        )
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: masterFileDescriptor,
            queue: queue
        )

        processSource.setEventHandler { [weak self] in
            self?.handleProcessExit()
        }
        processSource.setCancelHandler {}
        readSource.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        readSource.setCancelHandler { [master = masterFileDescriptor] in
            Darwin.close(master)
        }
        processSource.resume()
        readSource.resume()

        emitter.yield(.ready(.init(mergesStandardError: true)))
    }

    func sendStdin(_ data: Data) async throws {
        try Self.withOpenState(lock: stateLock, didClose: &didClose) {
            var remaining = data
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { bytes in
                    write(masterFileDescriptor, bytes.baseAddress, remaining.count)
                }
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        try Self.waitUntilWritable(masterFileDescriptor)
                        continue
                    }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                remaining.removeFirst(Int(written))
            }
        }
    }

    func resize(_ event: LoomShellResizeEvent) async throws {
        try Self.withOpenState(lock: stateLock, didClose: &didClose) {
            var windowSize = winsize(
                ws_row: UInt16(clamping: event.rows),
                ws_col: UInt16(clamping: event.columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            Self.signalProcessGroup(
                foregroundProcessGroupID: foregroundProcessGroupID(),
                fallbackProcessGroupID: sessionProcessGroupID,
                signal: SIGWINCH
            )
        }
    }

    func close() async {
        let alreadyClosed = markClosed()
        guard !alreadyClosed else { return }

        Self.terminateProcessGroups(
            foregroundProcessGroupID: foregroundProcessGroupID(),
            sessionProcessGroupID: sessionProcessGroupID
        )
        readSource.cancel()

        if let exitCode = reapChild(noHang: true) {
            finalizeTermination(exitCode: exitCode)
        }
    }

    private func readAvailableOutput() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let result = read(masterFileDescriptor, &buffer, buffer.count)
            if result > 0 {
                emitter.yield(.stdout(Data(buffer.prefix(result))))
                continue
            }
            if result == 0 {
                readSource.cancel()
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }

            emitter.yield(.failure("Local PTY read failed: \(String(cString: strerror(errno)))"))
            emitter.finish()
            processSource.cancel()
            readSource.cancel()
            return
        }
    }

    private func handleProcessExit() {
        guard let exitCode = reapChild(noHang: false) else {
            return
        }
        finalizeTermination(exitCode: exitCode)
    }

    private func finalizeTermination(exitCode: Int32) {
        _ = markClosed()
        emitter.yield(.exit(.init(exitCode: exitCode)))
        emitter.finish()
        processSource.cancel()
        readSource.cancel()
    }

    private func foregroundProcessGroupID() -> pid_t? {
        let processGroupID = tcgetpgrp(masterFileDescriptor)
        guard processGroupID > 0 else {
            return nil
        }
        return processGroupID
    }

    private func reapChild(noHang: Bool) -> Int32? {
        stateLock.lock()
        if didReapChild {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()

        var status: Int32 = 0
        let options = noHang ? WNOHANG : 0

        while true {
            let result = waitpid(childProcessID, &status, options)
            if result == 0 {
                return nil
            }
            if result == childProcessID {
                stateLock.lock()
                didReapChild = true
                stateLock.unlock()
                return Self.exitCode(fromWaitStatus: status)
            }
            if errno == EINTR {
                continue
            }
            if errno == ECHILD {
                stateLock.lock()
                didReapChild = true
                stateLock.unlock()
                return nil
            }

            emitter.yield(.failure("Local shell waitpid failed: \(String(cString: strerror(errno)))"))
            emitter.finish()
            processSource.cancel()
            readSource.cancel()
            return nil
        }
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowBits = status & 0x7f
        if lowBits == 0 {
            return (status >> 8) & 0xff
        }
        if lowBits != 0x7f {
            return -lowBits
        }
        return status
    }

    private struct LoginUserContext {
        let username: String
        let homeDirectory: String
        let shellPath: String
    }

    private static func currentLoginUserContext() -> LoginUserContext? {
        let configuredBufferSize = sysconf(Int32(_SC_GETPW_R_SIZE_MAX))
        let bufferSize = max(configuredBufferSize > 0 ? Int(configuredBufferSize) : 0, 4 * 1024)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var passwdEntry = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        let status = getpwuid_r(getuid(), &passwdEntry, buffer, bufferSize, &result)
        guard status == 0, let record = result else {
            return nil
        }

        let username = String(cString: record.pointee.pw_name)
        let homeDirectory = String(cString: record.pointee.pw_dir)
        let shellPath = String(cString: record.pointee.pw_shell)

        return LoginUserContext(
            username: username,
            homeDirectory: homeDirectory,
            shellPath: shellPath
        )
    }

    private static func resolvedShellPath(
        environment: [String: String],
        loginUser: LoginUserContext?
    ) -> String {
        if let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }
        if let shell = loginUser?.shellPath.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func arguments(for request: LoomShellSessionRequest) -> [String] {
        if let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return ["-ilc", command]
        }
        return ["-il"]
    }

    private static func environment(
        for request: LoomShellSessionRequest,
        loginUser: LoginUserContext?,
        shellPath: String
    ) -> [String: String] {
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var environment = inheritedEnvironment.reduce(into: [String: String]()) { partialResult, element in
            let (key, value) = element
            if key == "PATH" || key == "TMPDIR" || key == "SSH_AUTH_SOCK" || key == "__CF_USER_TEXT_ENCODING" ||
                key == "LANG" || key.hasPrefix("LC_") {
                partialResult[key] = value
            }
        }

        if let loginUser {
            environment["HOME"] = loginUser.homeDirectory
            environment["USER"] = loginUser.username
            environment["LOGNAME"] = loginUser.username
        }
        environment["SHELL"] = shellPath
        environment.merge(request.environment, uniquingKeysWith: { _, new in new })
        environment["TERM"] = request.terminalType
        environment["COLUMNS"] = String(request.columns)
        environment["LINES"] = String(request.rows)
        return environment
    }

    private static func workingDirectory(
        for request: LoomShellSessionRequest,
        loginUser: LoginUserContext?
    ) -> String? {
        if let workingDirectory = request.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            return workingDirectory
        }
        if let homeDirectory = request.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !homeDirectory.isEmpty {
            return homeDirectory
        }
        if let homeDirectory = loginUser?.homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
           !homeDirectory.isEmpty {
            return homeDirectory
        }
        return nil
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func waitUntilWritable(_ fileDescriptor: Int32) throws {
        var descriptor = pollfd(
            fd: fileDescriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        while true {
            let result = poll(&descriptor, 1, -1)
            if result > 0 {
                return
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static func spawnShell(
        request: LoomShellSessionRequest,
        initialWindowSize: inout winsize
    ) throws -> SpawnedShellProcess {
        let loginUser = currentLoginUserContext()
        let shellPath = resolvedShellPath(
            environment: request.environment,
            loginUser: loginUser
        )
        let arguments = [shellPath] + arguments(for: request)
        let environmentStrings = environment(
            for: request,
            loginUser: loginUser,
            shellPath: shellPath
        ).map { key, value in
            "\(key)=\(value)"
        }
        let workingDirectory = workingDirectory(
            for: request,
            loginUser: loginUser
        )

        // Keep the child-side PTY/session setup in C so no Swift runtime code runs between fork and exec.
        return try withCString(shellPath) { shellPathPointer in
            try withCStringArray(arguments) { argumentPointers in
                try withCStringArray(environmentStrings) { environmentPointers in
                    try withOptionalCString(workingDirectory) { workingDirectoryPointer in
                        var masterFileDescriptor: Int32 = -1
                        let pid = loom_shell_forkpty_spawn(
                            &masterFileDescriptor,
                            shellPathPointer,
                            argumentPointers,
                            environmentPointers,
                            workingDirectoryPointer,
                            &initialWindowSize
                        )
                        guard pid >= 0 else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                        return SpawnedShellProcess(
                            pid: pid,
                            processGroupID: pid,
                            masterFileDescriptor: masterFileDescriptor
                        )
                    }
                }
            }
        }
    }

    private static func withCString<T>(
        _ string: String,
        body: (UnsafePointer<CChar>) throws -> T
    ) throws -> T {
        guard let copy = strdup(string) else {
            throw POSIXError(.init(rawValue: errno) ?? .ENOMEM)
        }
        defer { free(copy) }
        return try body(copy)
    }

    private static func withOptionalCString<T>(
        _ string: String?,
        body: (UnsafePointer<CChar>?) throws -> T
    ) throws -> T {
        guard let string else {
            return try body(nil)
        }
        return try withCString(string) { pointer in
            try body(pointer)
        }
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var copies: [UnsafeMutablePointer<CChar>] = []
        copies.reserveCapacity(strings.count)

        do {
            for string in strings {
                guard let copy = strdup(string) else {
                    throw POSIXError(.init(rawValue: errno) ?? .ENOMEM)
                }
                copies.append(copy)
            }
        } catch {
            copies.forEach { free($0) }
            throw error
        }

        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: copies.count + 1)
        buffer.initialize(repeating: nil, count: copies.count + 1)
        for (index, copy) in copies.enumerated() {
            buffer[index] = copy
        }

        defer {
            buffer.deinitialize(count: copies.count + 1)
            buffer.deallocate()
            copies.forEach { free($0) }
        }

        return try body(buffer)
    }

    private static func signalProcessGroup(
        foregroundProcessGroupID: pid_t?,
        fallbackProcessGroupID: pid_t,
        signal: Int32
    ) {
        if let foregroundProcessGroupID, foregroundProcessGroupID > 0 {
            _ = kill(-foregroundProcessGroupID, signal)
            if foregroundProcessGroupID == fallbackProcessGroupID {
                return
            }
        }
        _ = kill(-fallbackProcessGroupID, signal)
    }

    private static func terminateProcessGroups(
        foregroundProcessGroupID: pid_t?,
        sessionProcessGroupID: pid_t
    ) {
        signalProcessGroup(
            foregroundProcessGroupID: foregroundProcessGroupID,
            fallbackProcessGroupID: sessionProcessGroupID,
            signal: SIGHUP
        )
        signalProcessGroup(
            foregroundProcessGroupID: foregroundProcessGroupID,
            fallbackProcessGroupID: sessionProcessGroupID,
            signal: SIGCONT
        )
        signalProcessGroup(
            foregroundProcessGroupID: foregroundProcessGroupID,
            fallbackProcessGroupID: sessionProcessGroupID,
            signal: SIGTERM
        )
    }

    private static func forceTerminateProcessGroup(_ processGroupID: pid_t) {
        _ = kill(-processGroupID, SIGHUP)
        _ = kill(-processGroupID, SIGCONT)
        _ = kill(-processGroupID, SIGKILL)
    }

    private static func withOpenState<T>(
        lock: NSLock,
        didClose: inout Bool,
        body: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !didClose else {
            throw LoomShellError.protocolViolation("Local shell session is already closed.")
        }
        return try body()
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let alreadyClosed = didClose
        didClose = true
        return alreadyClosed
    }
}

private struct SpawnedShellProcess {
    let pid: pid_t
    let processGroupID: pid_t
    let masterFileDescriptor: Int32
}
#endif
