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
// HOMEBREW_NO_AUTOREMOVE=1 stops `uninstall` and `cleanup` from running an implicit autoremove.

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
    /// Only lines sudo itself writes to stderr count, so package output can't trigger this.
    public var needsAdminPassword: Bool {
        stderr.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return line.hasPrefix("sudo:")
                && ["a terminal is required", "a password is required", "no tty present", "askpass"].contains { line.contains($0) }
        }
    }

    /// Installed versions ("kegs") brew couldn't delete because some files in them belong to another user
    /// (usually root, after something was run with sudo). brew reports these on stderr as
    ///   `Error: Could not cleanup old kegs! Fix your permissions on:` + indented paths   (cmd/cleanup.rb)
    ///   `Error: Could not remove NAME keg! Do so manually:` + `  sudo rm -rf PATH`        (keg.rb)
    ///
    /// The result feeds a `sudo chown` suggestion, and package output can contain anything, so this is strict:
    /// only stderr, only lines directly after brew's own error line, only paths shaped exactly
    /// `<prefix>/Cellar/<name>/<version>` in plain ASCII, and only if every part of that path is a real
    /// directory rather than a symlink (checked by `isRealDirectory`).
    public func permissionBlockedKegs(
        prefix: String,
        isRealDirectory: (String) -> Bool = BrewResult.isRealDirectory
    ) -> [String] {
        var paths: [String] = []
        var collecting = false
        for raw in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Error: Could not cleanup old kegs! Fix your permissions on:")
                || (line.hasPrefix("Error: Could not remove ") && line.hasSuffix(" keg! Do so manually:")) {
                collecting = true
                continue
            }
            guard collecting else { continue }
            let candidate = line.hasPrefix("sudo rm -rf ") ? String(line.dropFirst("sudo rm -rf ".count)) : line
            // The list ends at the first line that isn't a path; a path that fails validation is skipped.
            guard candidate.hasPrefix("/") else {
                collecting = false
                continue
            }
            if let keg = Self.validKegPath(candidate, prefix: prefix, isRealDirectory: isRealDirectory), !paths.contains(keg) {
                paths.append(keg)
            }
        }
        return paths
    }

    static func validKegPath(_ path: String, prefix: String, isRealDirectory: (String) -> Bool) -> String? {
        let cellar = prefix + "/Cellar/"
        guard path.hasPrefix(cellar), path.unicodeScalars.allSatisfy(BrewText.isSafeASCII) else { return nil }
        let parts = path.dropFirst(cellar.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        // Every level must be a real directory: a symlink anywhere would let `chown` reach outside the prefix.
        let levels = [prefix, prefix + "/Cellar", cellar + parts[0], path]
        guard levels.allSatisfy(isRealDirectory) else { return nil }
        return path
    }

    /// True if `path` exists and is a directory, without following a symlink at the last component.
    public static func isRealDirectory(_ path: String) -> Bool {
        let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        return type == .typeDirectory
    }
}

/// Character rules for anything RootBeer passes to brew or shows as a command to paste.
enum BrewText {
    /// Plain ASCII that's safe unquoted in sh/zsh. `=` and `~` are left out: zsh expands a leading `=`
    /// (e.g. `=rm`), and `~` expands to a home directory.
    static func isSafeASCII(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "@", "%", "+", ":", ",", ".", "/", "_", "-": true
        default: false
        }
    }

    /// Homebrew formula and cask names: lowercase-ish ASCII words like `node@24`, `python@3.15`, `c-ares`.
    /// Must start with a letter or digit, so it can never read as a flag.
    static func isValidPackageName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, isAlphanumeric(first), scalars.count <= 200 else { return false }
        return scalars.allSatisfy { isAlphanumeric($0) || "@+._-".unicodeScalars.contains($0) }
    }

    /// Length of the longest prefix of `data` that doesn't end partway through a UTF-8 character.
    static func completeUTF8Length(_ data: Data) -> Int {
        let bytes = [UInt8](data.suffix(4))
        var start = bytes.count - 1
        // Step back over continuation bytes (10xxxxxx) to the last character's first byte.
        while start > 0, bytes[start] & 0b1100_0000 == 0b1000_0000 { start -= 1 }
        guard start >= 0, !bytes.isEmpty else { return data.count }
        let lead = bytes[start]
        let needed = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 1
        return bytes.count - start >= needed ? data.count : data.count - (bytes.count - start)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
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

    /// Settings that keep brew from doing anything RootBeer didn't ask for. Used for every brew process
    /// RootBeer runs and in every brew command it suggests pasting into Terminal.
    /// - NO_AUTO_UPDATE: no implicit `brew update`; updates are explicit only.
    /// - NO_INSTALL_CLEANUP: upgrades don't delete old versions; that's the Cleanup button.
    /// - NO_AUTOREMOVE: since Homebrew 4.3, `brew uninstall` and `brew cleanup` otherwise run a system-wide
    ///   `brew autoremove`, removing unrelated orphans. RootBeer removes dependencies itself, one by one.
    public static let safetyVariables: [(name: String, value: String)] = [
        ("HOMEBREW_NO_AUTO_UPDATE", "1"),
        ("HOMEBREW_NO_INSTALL_CLEANUP", "1"),
        ("HOMEBREW_NO_AUTOREMOVE", "1"),
    ]

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
        for variable in safetyVariables { env[variable.name] = variable.value }
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
        guard BrewText.isValidPackageName(formula) else { throw BrewError.invalidPackageName(formula) }
        return try await checked(["uses", "--installed", formula]).stdout
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
        // Names come from brew's JSON, which third-party taps control. Anything that isn't a plain
        // package name (e.g. one that starts with `-` and would read as a flag) is refused.
        if let name = action.packageName, !BrewText.isValidPackageName(name) {
            throw BrewError.invalidPackageName(name)
        }
        return try await run(action.arguments, onOutput: onOutput)
    }

    /// What to paste into Terminal when brew needs a password RootBeer can't supply. Carries the same
    /// safety settings RootBeer uses, so the pasted command can't trigger an implicit autoremove.
    public nonisolated func terminalCommand(for action: BrewAction) -> String {
        let settings = BrewLocator.safetyVariables.map { "\($0.name)=\($0.value)" }
        return (settings + [Self.shellQuoted(brewURL.path)] + action.arguments.map(Self.shellQuoted))
            .joined(separator: " ")
    }

    /// Homebrew's install prefix, e.g. /opt/homebrew.
    public nonisolated var prefix: String {
        brewURL.deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Hands kegs brew couldn't delete back to the current user, so a retry can remove them through brew.
    /// Full paths to sudo and chown so a same-named tool earlier in the user's PATH (e.g. in
    /// /opt/homebrew/bin) can't intercept the password; `-P` so chown never follows symlinks inside.
    /// Pass only paths from `BrewResult.permissionBlockedKegs`.
    public nonisolated func permissionFixCommand(for kegs: [String], user: String = NSUserName()) -> String {
        (["/usr/bin/sudo", "/usr/sbin/chown", "-R", "-P", "\(user):admin"] + kegs).map(Self.shellQuoted).joined(separator: " ")
    }

    /// Leaves plain ASCII words alone and single-quotes everything else.
    static func shellQuoted(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(BrewText.isSafeASCII) { return word }
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
                        // Read to EOF so no trailing output is lost after the process exits. A multi-byte
                        // character can be split across chunks, so only complete characters are streamed.
                        var pending = Data()
                        func emit(_ bytes: Data) {
                            let text = String(decoding: bytes, as: UTF8.self)
                            onOutput?(isStdout ? .stdout(text) : .stderr(text))
                        }
                        while case let chunk = handle.availableData, !chunk.isEmpty {
                            buffer.append(chunk)
                            pending.append(chunk)
                            let complete = BrewText.completeUTF8Length(pending)
                            if complete > 0 {
                                emit(pending.prefix(complete))
                                pending.removeFirst(complete)
                            }
                        }
                        if !pending.isEmpty { emit(pending) }
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
