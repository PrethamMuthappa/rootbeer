import Foundation

// MARK: - Every Homebrew invocation in RootBeer lives in this file.
//
// Audit guide: the only place a `brew` process is started is `BrewRunner.execute`, and
// `BrewRunner.run` is private. The complete list of brew commands RootBeer can run:
//
// Read-only (BrewRunner methods):
//   brew info --installed --json=v2        installedInfoJSON()
//   brew outdated --json=v2                outdatedJSON()
//   brew uses --installed NAME             installedUses(of:)
//   brew autoremove --dry-run              autoremoveDryRun()
//   brew cleanup --dry-run                 cleanupDryRun()
//
// Changes the system (BrewAction, run only through BrewRunner.perform):
//   brew update                            .update
//   brew upgrade                           .upgradeAll
//   brew upgrade --formula|--cask NAME     .upgrade
//   brew uninstall --formula|--cask NAME   .uninstall
//   brew cleanup                           .cleanup
//
// Never used: --zap, plain `brew autoremove`, --ignore-dependencies, --force, --greedy.

public enum BrewError: Error, LocalizedError, Sendable {
    case brewNotFound
    case launchFailed(String)
    case commandFailed(BrewResult)
    case invalidPackageName(String)

    public var errorDescription: String? {
        switch self {
        case .brewNotFound:
            "RootBeer couldn't find Homebrew at /opt/homebrew/bin/brew or /usr/local/bin/brew."
        case .launchFailed(let message):
            "RootBeer couldn't start brew: \(message)"
        case .commandFailed(let result):
            "`\(result.commandLine)` failed with exit status \(result.exitCode).\n\(result.stderr)"
        case .invalidPackageName(let name):
            "RootBeer refused to run brew with the package name \"\(name)\"."
        }
    }
}

public struct BrewResult: Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
    public var commandLine: String { (["brew"] + arguments).joined(separator: " ") }

    /// brew ran sudo (e.g. a cask's pkg uninstaller) and there was no terminal to ask for the password.
    public var needsAdminPassword: Bool {
        let text = (stderr + "\n" + stdout).lowercased()
        return ["sudo: a terminal is required", "sudo: a password is required", "sudo: no tty present", "askpass"]
            .contains { text.contains($0) }
    }
}

public enum BrewOutput: Sendable {
    case stdout(String)
    case stderr(String)
}

/// Every brew command that changes the system. Arguments are spelled out here and nowhere else.
public enum BrewAction: Sendable, Hashable {
    case update
    case upgradeAll
    case upgrade(PackageKind, String)
    case uninstall(PackageKind, String)
    case cleanup

    public static func upgrade(_ package: Package) -> BrewAction { .upgrade(package.kind, package.name) }
    public static func uninstall(_ package: Package) -> BrewAction { .uninstall(package.kind, package.name) }

    public var arguments: [String] {
        switch self {
        case .update: ["update"]
        case .upgradeAll: ["upgrade"]
        case .upgrade(let kind, let name): ["upgrade", kind.flag, name]
        case .uninstall(let kind, let name): ["uninstall", kind.flag, name]
        case .cleanup: ["cleanup"]
        }
    }

    public var commandLine: String { (["brew"] + arguments).joined(separator: " ") }

    var packageName: String? {
        switch self {
        case .upgrade(_, let name), .uninstall(_, let name): name
        case .update, .upgradeAll, .cleanup: nil
        }
    }
}

extension PackageKind {
    var flag: String {
        switch self {
        case .formula: "--formula"
        case .cask: "--cask"
        }
    }
}

public enum BrewLocator {
    public static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static func find() -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// GUI apps don't inherit the shell PATH, so every brew process gets an explicit one.
    static func environment(for brew: URL) -> [String: String] {
        let prefix = brew.deletingLastPathComponent().deletingLastPathComponent().path
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"] {
            env[key] = inherited[key]
        }
        env["PATH"] = ["\(prefix)/bin", "\(prefix)/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
        // Never let a read trigger an implicit `brew update`; updates are explicit only.
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        // Likewise, upgrades don't clean up old versions behind your back; that's the Cleanup button.
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        return env
    }

    /// Roughly when Homebrew's package data was last refreshed, from its API cache files.
    /// Reads file dates only; doesn't run brew. `nil` if unknown.
    public static func metadataUpdatedAt() -> Date? {
        let api = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Homebrew/api")
        return ["formula_names.txt", "cask_names.txt"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: api.appendingPathComponent($0).path)[.modificationDate] as? Date }
            .max()
    }
}

/// Runs brew commands strictly one at a time. Concurrent brew calls fight over locks.
///
/// Actor methods are reentrant across `await`, so actor isolation alone doesn't
/// serialize them. Each call chains onto the previous one through `tail`.
public actor BrewRunner {
    public let brewURL: URL
    private let environment: [String: String]
    private var tail: Task<Void, Never>?

    public init(brewURL: URL) {
        self.brewURL = brewURL
        self.environment = BrewLocator.environment(for: brewURL)
    }

    public static func located() throws -> BrewRunner {
        guard let url = BrewLocator.find() else { throw BrewError.brewNotFound }
        return BrewRunner(brewURL: url)
    }

    // MARK: Read-only commands

    public func installedInfoJSON() async throws -> Data {
        try await checked(["info", "--installed", "--json=v2"]).stdoutData
    }

    public func outdatedJSON() async throws -> Data {
        try await checked(["outdated", "--json=v2"]).stdoutData
    }

    /// Installed formulae that depend on `formula`. Formulae only: brew can't answer this for casks.
    public func installedUses(of formula: String) async throws -> [String] {
        try await checked(["uses", "--installed", formula]).stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Full names of formulae `brew autoremove` would remove right now. Never runs plain `autoremove`.
    public func autoremoveDryRun() async throws -> [String] {
        Self.parseAutoremoveDryRun(try await checked(["autoremove", "--dry-run"]).stdout)
    }

    public func cleanupDryRun() async throws -> BrewResult {
        try await checked(["cleanup", "--dry-run"])
    }

    /// Output is `==> Would autoremove N unneeded formulae:` followed by one full name per line,
    /// or nothing at all when there are no orphans (Homebrew's cleanup.rb).
    public static func parseAutoremoveDryRun(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.hasPrefix("Warning:") && !$0.hasPrefix("Error:") && !$0.contains(" ") }
    }

    // MARK: Commands that change the system

    /// Runs a `BrewAction`. A non-zero exit is returned, not thrown, so callers must check `succeeded`.
    public func perform(
        _ action: BrewAction,
        onOutput: (@Sendable (BrewOutput) -> Void)? = nil
    ) async throws -> BrewResult {
        // A name that looks like a flag would change the command's meaning.
        if let name = action.packageName, name.isEmpty || name.hasPrefix("-") {
            throw BrewError.invalidPackageName(name)
        }
        return try await run(action.arguments, onOutput: onOutput)
    }

    /// What to paste into Terminal when brew needs a password RootBeer can't supply.
    public nonisolated func terminalCommand(for action: BrewAction) -> String {
        (["HOMEBREW_NO_AUTO_UPDATE=1", Self.shellQuoted(brewURL.path)] + action.arguments.map(Self.shellQuoted))
            .joined(separator: " ")
    }

    static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Execution

    private func checked(_ arguments: [String]) async throws -> BrewResult {
        let result = try await run(arguments)
        guard result.succeeded else { throw BrewError.commandFailed(result) }
        return result
    }

    /// Runs `brew arguments`, streaming output chunks to `onOutput` from a background thread.
    /// Private on purpose: callers outside this file can only use the named commands above.
    private func run(
        _ arguments: [String],
        onOutput: (@Sendable (BrewOutput) -> Void)? = nil
    ) async throws -> BrewResult {
        let previous = tail
        let brew = brewURL
        let env = environment
        let job = Task {
            _ = await previous?.value
            return try await Self.execute(brew: brew, arguments: arguments, environment: env, onOutput: onOutput)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    private static func execute(
        brew: URL,
        arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (BrewOutput) -> Void)?
    ) async throws -> BrewResult {
        RootBeerLog.info("running: brew \(arguments.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = brew
                process.arguments = arguments
                process.environment = environment
                // No terminal: anything that prompts (e.g. sudo) fails instead of hanging.
                process.standardInput = FileHandle.nullDevice
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: BrewError.launchFailed(error.localizedDescription))
                    return
                }

                let outData = LockedData(), errData = LockedData()
                let group = DispatchGroup()
                let streams = [
                    (outPipe.fileHandleForReading, outData, true),
                    (errPipe.fileHandleForReading, errData, false),
                ]
                for (handle, buffer, isStdout) in streams {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        // Read to EOF so no trailing output is lost after the process exits.
                        while case let chunk = handle.availableData, !chunk.isEmpty {
                            buffer.append(chunk)
                            let text = String(decoding: chunk, as: UTF8.self)
                            onOutput?(isStdout ? .stdout(text) : .stderr(text))
                        }
                        group.leave()
                    }
                }
                group.wait()
                process.waitUntilExit()

                let result = BrewResult(
                    arguments: arguments,
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData.value, as: UTF8.self),
                    stderr: String(decoding: errData.value, as: UTF8.self)
                )
                RootBeerLog.info("finished: \(result.commandLine) → exit \(result.exitCode)")
                continuation.resume(returning: result)
            }
        }
    }
}

extension BrewResult {
    var stdoutData: Data { Data(stdout.utf8) }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var value: Data { lock.withLock { data } }
}

public enum RootBeerLog {
    public static func info(_ message: String) {
        FileHandle.standardError.write(Data("[RootBeer] \(message)\n".utf8))
    }
}
