import Foundation
import Observation
import RootBeerCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case formulae = "Formulae"
    case casks = "Casks"
    case outdated = "Outdated"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .formulae: "terminal"
        case .casks: "macwindow"
        case .outdated: "arrow.up.circle"
        }
    }

    func includes(_ package: Package) -> Bool {
        switch self {
        case .all: true
        case .formulae: package.kind == .formula
        case .casks: package.kind == .cask
        case .outdated: package.isOutdated
        }
    }
}

enum UsesState: Equatable {
    case loading
    case loaded([String])
    case failed(String)
}

struct LogEntry: Identifiable {
    enum Kind { case command, stdout, stderr, info, success, failure }
    let id: Int
    let kind: Kind
    var text: String
}

/// The result of the last operation. Success is only ever set after a zero exit status.
struct Outcome {
    let title: String
    let succeeded: Bool
    let detail: String
    var terminalCommand: String?
}

/// What the user saw when they opened a confirmation, so the confirmation can say how fresh it is.
struct DataSnapshot {
    let loadedAt: Date
    let metadataUpdatedAt: Date?
    let updatedThisSession: Bool

    /// Unless Update Homebrew succeeded in this session before the list was loaded, assume it may be stale.
    var mayBeStale: Bool { !updatedThisSession }
}

enum ActiveSheet: Identifiable {
    case upgradeAll([Package], DataSnapshot)
    case upgrade(Package, DataSnapshot)
    case uninstallCask(Package)
    case uninstallFormula(UninstallDraft)
    case cleanup(String)

    var id: String {
        switch self {
        case .upgradeAll: "upgradeAll"
        case .upgrade(let p, _): "upgrade:\(p.id)"
        case .uninstallCask(let p): "uninstallCask:\(p.id)"
        case .uninstallFormula(let d): "uninstallFormula:\(d.target.id)"
        case .cleanup: "cleanup"
        }
    }
}

/// The choices made in the formula uninstall sheet. The plan is recomputed from them on every change.
@MainActor
@Observable
final class UninstallDraft {
    let target: Package
    let graph: DependencyGraph
    var includedDependents: Set<Package.ID> = []
    var excludedDependencies: Set<Package.ID> = []
    /// Only clears RootBeer's own blocking warning. It never changes what brew is asked to do.
    var force = false

    init(target: Package, graph: DependencyGraph) {
        self.target = target
        self.graph = graph
    }

    var plan: RemovalPlan {
        RemovalPlanner.plan(
            target: target.id,
            graph: graph,
            includedDependents: includedDependents,
            excludedDependencies: excludedDependencies
        )
    }

    var canConfirm: Bool { !plan.isBlocked || force }

    func package(_ id: Package.ID) -> Package? { graph.packages[id] }
}

@MainActor
@Observable
final class AppModel {
    private(set) var inventory = Inventory.empty
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var uses: [String: UsesState] = [:]
    private(set) var inventoryLoadedAt: Date?

    private(set) var log: [LogEntry] = []
    private(set) var activeOperation: String?
    private(set) var outcome: Outcome?
    private var lastSuccessfulUpdate: Date?
    private var nextLogID = 0

    var sidebarSelection: SidebarItem? = .all
    var searchText = ""
    var selectedID: Package.ID?
    var sheet: ActiveSheet?
    var showLog = false

    private let runner: BrewRunner?

    init() {
        do {
            runner = try BrewRunner.located()
        } catch {
            runner = nil
            loadError = error.localizedDescription
        }
    }

    /// True while brew is doing anything. Every action button is disabled while this is set.
    var isBusy: Bool { isLoading || activeOperation != nil }

    var selectedPackage: Package? {
        inventory.packages.first { $0.id == selectedID }
    }

    var outdatedPackages: [Package] { inventory.packages.filter(\.isOutdated) }

    func count(for item: SidebarItem) -> Int {
        inventory.packages.count(where: item.includes)
    }

    var visiblePackages: [Package] {
        let item = sidebarSelection ?? .all
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return inventory.packages.filter { package in
            item.includes(package) && (query.isEmpty
                || package.name.localizedCaseInsensitiveContains(query)
                || package.displayName.localizedCaseInsensitiveContains(query)
                || (package.desc?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    func package(named name: String) -> Package? {
        inventory.packages.first { $0.kind == .formula && $0.name == name }
    }

    // MARK: Loading (read-only)

    func reload() async {
        guard let runner, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await runner.installedInfoJSON()
            let outdated = try await runner.outdatedJSON()
            inventory = try await Task.detached { try Inventory.parse(info: info, outdated: outdated) }.value
            inventoryLoadedAt = Date()
            uses = [:]
            loadError = nil
            RootBeerLog.info("loaded \(count(for: .formulae)) formulae, \(count(for: .casks)) casks, \(count(for: .outdated)) outdated")
            if let selectedID, !inventory.packages.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        } catch {
            loadError = error.localizedDescription
            RootBeerLog.info("failed to load packages: \(error.localizedDescription)")
        }
    }

    func loadUses(for package: Package) async {
        guard let runner, package.kind == .formula, uses[package.name] == nil else { return }
        uses[package.name] = .loading
        do {
            uses[package.name] = .loaded(try await runner.installedUses(of: package.name))
        } catch {
            uses[package.name] = .failed(error.localizedDescription)
        }
    }

    // MARK: Opening confirmations (nothing runs here)

    private var snapshot: DataSnapshot {
        let loadedAt = inventoryLoadedAt ?? Date()
        return DataSnapshot(
            loadedAt: loadedAt,
            metadataUpdatedAt: BrewLocator.metadataUpdatedAt(),
            updatedThisSession: lastSuccessfulUpdate.map { $0 <= loadedAt } ?? false
        )
    }

    func requestUpgradeAll() {
        guard !isBusy else { return }
        sheet = .upgradeAll(outdatedPackages, snapshot)
    }

    func requestUpgrade(_ package: Package) {
        guard !isBusy, package.isOutdated else { return }
        sheet = .upgrade(package, snapshot)
    }

    func requestUninstall(_ package: Package) {
        guard !isBusy else { return }
        switch package.kind {
        case .cask: sheet = .uninstallCask(package)
        case .formula: sheet = .uninstallFormula(UninstallDraft(target: package, graph: DependencyGraph(inventory.packages)))
        }
    }

    /// Runs `brew cleanup --dry-run` (read-only) and shows its output for confirmation.
    func requestCleanup() async {
        guard let runner, !isBusy else { return }
        activeOperation = "Checking what Cleanup would remove"
        defer { activeOperation = nil }
        showLog = true
        appendLog(.command, "$ brew cleanup --dry-run")
        do {
            let result = try await runner.cleanupDryRun()
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog(.stdout, output.isEmpty ? "(no output)\n" : output + "\n")
            appendLog(.success, "exit status 0")
            sheet = .cleanup(output)
        } catch {
            appendLog(.failure, error.localizedDescription)
            outcome = Outcome(title: "Cleanup", succeeded: false, detail: error.localizedDescription)
        }
    }

    // MARK: Operations that change the system. Each is called only from a confirmation sheet
    // or the Update Homebrew button.

    func updateHomebrew() async {
        await operation("Update Homebrew") {
            guard let result = await step(.update), result.succeeded else {
                return failure("Update Homebrew", .update)
            }
            lastSuccessfulUpdate = Date()
            return Outcome(title: "Update Homebrew", succeeded: true, detail: "Homebrew's package data is up to date.")
        }
    }

    func upgradeAll() async {
        await operation("Upgrade All") {
            guard let result = await step(.upgradeAll), result.succeeded else {
                return failure("Upgrade All", .upgradeAll)
            }
            return Outcome(title: "Upgrade All", succeeded: true, detail: "brew upgrade finished.")
        }
    }

    func upgrade(_ package: Package) async {
        let action = BrewAction.upgrade(package)
        await operation("Upgrade \(package.name)") {
            guard let result = await step(action), result.succeeded else {
                return failure("Upgrade \(package.name)", action)
            }
            return Outcome(title: "Upgrade \(package.name)", succeeded: true, detail: "Upgraded \(package.name).")
        }
    }

    func uninstallCask(_ cask: Package) async {
        let action = BrewAction.uninstall(cask)
        await operation("Uninstall \(cask.name)") {
            guard cask.kind == .cask else { return Outcome(title: "Uninstall", succeeded: false, detail: "Not a cask.") }
            guard let result = await step(action), result.succeeded else {
                return failure("Uninstall \(cask.name)", action)
            }
            return Outcome(title: "Uninstall \(cask.name)", succeeded: true, detail: "Uninstalled \(cask.name).")
        }
    }

    /// Formula uninstall with dependency cleanup:
    /// 1. Recompute the plan from the current package list and refuse if it differs from what was confirmed.
    /// 2. Uninstall the selected package and ticked dependents by name, stopping at the first failure.
    /// 3. Run `brew autoremove --dry-run` as a cross-check.
    /// 4. Uninstall each planned dependency that brew lists, one at a time; skip and log any it doesn't list.
    func uninstall(confirmed shown: RemovalPlan, force: Bool) async {
        guard let runner, let target = inventory.packages.first(where: { $0.id == shown.target }) else { return }
        let title = "Uninstall \(target.name)"
        await operation(title) {
            let graph = DependencyGraph(inventory.packages)
            let plan = RemovalPlanner.plan(
                target: shown.target,
                graph: graph,
                includedDependents: Set(shown.roots).subtracting([shown.target]),
                excludedDependencies: shown.excludedDependencies
            )
            guard plan == shown else {
                return Outcome(title: title, succeeded: false,
                               detail: "The installed packages changed after this was planned. Nothing was removed. Open Uninstall again to review.")
            }
            guard !plan.isBlocked || force else {
                return Outcome(title: title, succeeded: false, detail: "Other packages still depend on this. Nothing was removed.")
            }
            let name = graph.name
            appendLog(.info, "Plan: uninstall \(plan.roots.map(name).joined(separator: ", "))"
                + (plan.dependencies.isEmpty ? "" : "; then dependencies \(plan.dependencies.map(name).joined(separator: ", ")) if brew autoremove --dry-run lists them") + "\n")

            var removed: [String] = []
            for id in plan.roots {
                guard let package = graph.packages[id] else { continue }
                let action = BrewAction.uninstall(package)
                guard let result = await step(action), result.succeeded else {
                    let rest = plan.uninstallOrder.drop(while: { $0 != id }).dropFirst().map(name)
                    if !rest.isEmpty { appendLog(.info, "Not attempted: \(rest.joined(separator: ", "))\n") }
                    return failure(title, action, removedSoFar: removed)
                }
                removed.append(package.name)
            }

            guard !plan.dependencies.isEmpty else {
                return Outcome(title: title, succeeded: true, detail: "Removed \(removed.joined(separator: ", ")).")
            }

            appendLog(.command, "$ brew autoremove --dry-run")
            let listed: Set<String>
            do {
                let names = try await runner.autoremoveDryRun()
                appendLog(.stdout, names.isEmpty ? "(nothing listed)\n" : names.joined(separator: "\n") + "\n")
                appendLog(.success, "exit status 0")
                listed = Set(names)
            } catch {
                appendLog(.failure, error.localizedDescription)
                return Outcome(title: title, succeeded: false,
                               detail: "Removed \(removed.joined(separator: ", ")), but brew autoremove --dry-run failed, so no dependencies were removed.")
            }

            var skipped: [String] = []
            for id in plan.dependencies {
                guard let package = graph.packages[id] else { continue }
                guard listed.contains(package.fullName) || listed.contains(package.name) else {
                    skipped.append(package.name)
                    appendLog(.info, "Skipped \(package.name): planned, but brew autoremove --dry-run doesn't list it. It stays installed.\n")
                    continue
                }
                let action = BrewAction.uninstall(package)
                guard let result = await step(action), result.succeeded else {
                    return failure(title, action, removedSoFar: removed)
                }
                removed.append(package.name)
            }

            var detail = "Removed \(removed.joined(separator: ", "))."
            if !skipped.isEmpty { detail += " Kept \(skipped.joined(separator: ", ")) because brew didn't list them as unneeded." }
            return Outcome(title: title, succeeded: true, detail: detail)
        }
    }

    func cleanup() async {
        await operation("Cleanup") {
            guard let result = await step(.cleanup), result.succeeded else {
                return failure("Cleanup", .cleanup)
            }
            return Outcome(title: "Cleanup", succeeded: true, detail: "brew cleanup finished.")
        }
    }

    // MARK: Running

    private var lastFailure: BrewResult?

    /// Marks the app busy, runs `body`, records the outcome, then reloads the package list.
    private func operation(_ title: String, _ body: () async -> Outcome) async {
        guard runner != nil, !isBusy else { return }
        activeOperation = title
        outcome = nil
        lastFailure = nil
        showLog = true
        appendLog(.info, "── \(title) ──\n")
        let result = await body()
        outcome = result
        appendLog(result.succeeded ? .success : .failure, (result.succeeded ? "✓ " : "✗ ") + result.detail)
        RootBeerLog.info("\(title): \(result.succeeded ? "succeeded" : "FAILED") – \(result.detail)")
        activeOperation = nil
        await reload()
    }

    /// Runs one action, streaming its output into the log. Returns nil if brew couldn't be started.
    private func step(_ action: BrewAction) async -> BrewResult? {
        guard let runner else { return nil }
        appendLog(.command, "$ \(action.commandLine)")
        let (stream, continuation) = AsyncStream<BrewOutput>.makeStream()
        let pump = Task {
            for await chunk in stream { appendOutput(chunk) }
        }
        var result: BrewResult?
        do {
            result = try await runner.perform(action) { continuation.yield($0) }
        } catch {
            appendLog(.failure, error.localizedDescription)
        }
        continuation.finish()
        await pump.value
        if let result {
            appendLog(result.succeeded ? .success : .failure, "exit status \(result.exitCode)")
            if !result.succeeded { lastFailure = result }
        }
        return result
    }

    private func failure(_ title: String, _ action: BrewAction, removedSoFar removed: [String] = []) -> Outcome {
        let prefix = removed.isEmpty ? "" : "Removed \(removed.joined(separator: ", ")) before this. "
        guard let result = lastFailure else {
            return Outcome(title: title, succeeded: false, detail: prefix + "`\(action.commandLine)` couldn't be run.")
        }
        if result.needsAdminPassword, let runner {
            return Outcome(
                title: title, succeeded: false,
                detail: prefix + "`\(action.commandLine)` needs an administrator password, which RootBeer can't enter. Run this in Terminal:",
                terminalCommand: runner.terminalCommand(for: action)
            )
        }
        return Outcome(title: title, succeeded: false,
                       detail: prefix + "`\(action.commandLine)` failed with exit status \(result.exitCode). See the log for brew's error.")
    }

    // MARK: Log

    private func appendOutput(_ chunk: BrewOutput) {
        switch chunk {
        case .stdout(let text): appendLog(.stdout, text)
        case .stderr(let text): appendLog(.stderr, text)
        }
    }

    /// Consecutive stdout/stderr chunks merge into one entry so partial lines join up.
    private func appendLog(_ kind: LogEntry.Kind, _ text: String) {
        if (kind == .stdout || kind == .stderr), let last = log.indices.last, log[last].kind == kind {
            log[last].text += text
            return
        }
        nextLogID += 1
        log.append(LogEntry(id: nextLogID, kind: kind, text: text))
    }

    func clearLog() {
        guard !isBusy else { return }
        log = []
        outcome = nil
    }
}
