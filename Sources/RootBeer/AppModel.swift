import AppKit
import Observation
import RootBeerCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case formulae = "Formulae"
    case casks = "Casks"
    case outdated = "Outdated"
    case unused = "Unused"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .formulae: "terminal"
        case .casks: "macwindow"
        case .outdated: "arrow.up.circle"
        case .unused: "leaf"
        }
    }

    /// Whether the "Installed by me" filter means anything here. Casks are always installed on request,
    /// and everything in Unused is a dependency.
    var supportsRequestedFilter: Bool {
        switch self {
        case .all, .formulae, .outdated: true
        case .casks, .unused: false
        }
    }

    func includes(_ package: Package, unused: Set<Package.ID>) -> Bool {
        switch self {
        case .all: true
        case .formulae: package.kind == .formula
        case .casks: package.kind == .cask
        case .outdated: package.isOutdated
        case .unused: unused.contains(package.id)
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
    var detail: String
    var terminalCommand: String?
    /// Things that went differently than asked even though brew exited 0, e.g. a package brew removed
    /// without being asked, or one that's still outdated after an upgrade. Shown in orange.
    var warnings: [String] = []

    mutating func warn(_ message: String) {
        warnings.append(message)
        detail += " ⚠︎ " + message
    }
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
    /// The dry run's output, and whether it found anything to remove (stdout); stderr may only hold warnings.
    case cleanup(String, hasWork: Bool)

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
    /// Formulae `brew autoremove --dry-run` would remove: installed as dependencies, needed by nothing now.
    private(set) var unusedIDs: Set<Package.ID> = []
    /// Set when the dry run failed; the Unused section then can't be trusted.
    private(set) var unusedError: String?
    private(set) var inventoryLoadedAt: Date?

    private(set) var log: [LogEntry] = []
    /// Bumped on every log change, so the log view can follow new output cheaply.
    private(set) var logRevision = 0
    private(set) var activeOperation: String?
    private(set) var outcome: Outcome?
    private var lastSuccessfulUpdate: Date?
    private var nextLogID = 0
    /// Packages RootBeer explicitly uninstalled during the current operation.
    private var uninstalledThisOperation: Set<Package.ID> = []
    /// Set when the window is closed mid-operation: the app stays open until brew finishes, then quits.
    var quitWhenOperationFinishes = false

    var sidebarSelection: SidebarItem? = .all
    var searchText = ""
    var selectedID: Package.ID?
    var sheet: ActiveSheet?
    var showLog = false
    /// Hide packages brew installed only as dependencies. Remembered between launches.
    var showOnlyRequested = UserDefaults.standard.bool(forKey: AppModel.onlyRequestedKey) {
        didSet { UserDefaults.standard.set(showOnlyRequested, forKey: AppModel.onlyRequestedKey) }
    }
    private static let onlyRequestedKey = "RootBeer.showOnlyRequested"
    /// Height of the log panel; the panel's top edge can be dragged.
    var logHeight: CGFloat = 300
    /// The log height when a resize drag began; nil when not dragging.
    var logDragStartHeight: CGFloat?

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

    /// Counts what the grid would show for `item`, so sidebar numbers follow the filter.
    func count(for item: SidebarItem) -> Int {
        inventory.packages.count { shows($0, in: item) }
    }

    /// Dependencies in `item` that the "Installed by me" filter is hiding right now.
    func hiddenDependencyCount(for item: SidebarItem) -> Int {
        guard showOnlyRequested, item.supportsRequestedFilter else { return 0 }
        return inventory.packages.count { item.includes($0, unused: unusedIDs) && $0.isDependency }
    }

    private func shows(_ package: Package, in item: SidebarItem) -> Bool {
        guard item.includes(package, unused: unusedIDs) else { return false }
        return !(showOnlyRequested && item.supportsRequestedFilter && package.isDependency)
    }

    func isUnused(_ package: Package) -> Bool { unusedIDs.contains(package.id) }

    var visiblePackages: [Package] {
        let item = sidebarSelection ?? .all
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return inventory.packages.filter { package in
            shows(package, in: item) && (query.isEmpty
                || package.name.localizedCaseInsensitiveContains(query)
                || package.displayName.localizedCaseInsensitiveContains(query)
                || (package.desc?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    func package(named name: String) -> Package? {
        inventory.packages.first { $0.kind == .formula && $0.name == name }
    }

    /// True for the formula this running copy of RootBeer was installed from (`brew install rootbeer`).
    /// Uninstalling it from inside the app would delete the app while it runs.
    func isRootBeerItself(_ package: Package) -> Bool {
        guard package.kind == .formula, let runner else { return false }
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return app.hasPrefix(runner.prefix + "/Cellar/\(package.name)/")
    }

    /// Shown instead of an uninstall sheet for RootBeer itself.
    private func refuseSelfUninstall(_ package: Package) {
        showLog = true
        outcome = Outcome(
            title: "Uninstall \(package.name)", succeeded: false,
            detail: "This is the RootBeer you're running, so it can't remove itself. Quit RootBeer, then run this in Terminal:",
            terminalCommand: runner?.terminalCommand(for: .uninstall(package))
        )
    }

    // MARK: Loading (read-only)

    /// Reloads the package list. Ignored while an operation runs; the operation reloads itself.
    func reload() async {
        guard activeOperation == nil else { return }
        await loadInventory()
    }

    /// Loads the package list. Returns false if it couldn't, or if a load was already running.
    @discardableResult
    private func loadInventory() async -> Bool {
        guard let runner, !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await runner.installedInfoJSON()
            let outdated = try await runner.outdatedJSON()
            inventory = try await Task.detached { try Inventory.parse(info: info, outdated: outdated) }.value
            inventoryLoadedAt = Date()
            uses = [:]
            loadError = nil
            await loadUnused(runner)
            let packages = inventory.packages
            RootBeerLog.info("loaded \(packages.count { $0.kind == .formula }) formulae, \(packages.count { $0.kind == .cask }) casks, "
                + "\(packages.count(where: \.isOutdated)) outdated, \(unusedIDs.count) unused")
            if let selectedID, !inventory.packages.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            return true
        } catch {
            loadError = error.localizedDescription
            RootBeerLog.info("failed to load packages: \(error.localizedDescription)")
            return false
        }
    }

    /// Asks brew which formulae it considers unneeded. A failure here doesn't fail the reload;
    /// the Unused section shows the error instead.
    private func loadUnused(_ runner: BrewRunner) async {
        do {
            unusedIDs = inventory.formulaIDs(named: try await runner.autoremoveDryRun())
            unusedError = nil
        } catch {
            unusedIDs = []
            unusedError = error.localizedDescription
            RootBeerLog.info("couldn't list unused formulae: \(error.localizedDescription)")
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
        guard !isRootBeerItself(package) else {
            refuseSelfUninstall(package)
            return
        }
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
            let hasWork = !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sheet = .cleanup(output, hasWork: hasWork)
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
        } verify: { outcome, packages in
            // Pinned packages are skipped by design; anything else still outdated wasn't upgraded.
            let left = packages.filter { $0.isOutdated && !$0.isPinned }.map(\.name)
            if !left.isEmpty { outcome.warn("Still outdated after brew exited 0: \(left.joined(separator: ", ")).") }
        }
    }

    func upgrade(_ package: Package) async {
        let action = BrewAction.upgrade(package)
        await operation("Upgrade \(package.name)") {
            guard let result = await step(action), result.succeeded else {
                return failure("Upgrade \(package.name)", action)
            }
            return Outcome(title: "Upgrade \(package.name)", succeeded: true, detail: "Upgraded \(package.name).")
        } verify: { outcome, packages in
            guard let now = packages.first(where: { $0.id == package.id }) else { return }
            if now.isOutdated {
                outcome.warn("brew exited 0, but \(package.name) is still outdated (installed \(now.installedVersion)).")
            } else {
                outcome.detail = "Upgraded \(package.name) from \(package.installedVersion) to \(now.installedVersion)."
            }
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
    /// 1. Recompute the plan from a fresh package list (`operation` reloads first) and refuse if it
    ///    differs from what was confirmed, e.g. because something changed in Terminal meanwhile.
    /// 2. Uninstall the selected package and ticked dependents by name, stopping at the first failure.
    /// 3. Run `brew autoremove --dry-run` as a cross-check.
    /// 4. Uninstall each planned dependency that brew lists, one at a time; skip and log any it doesn't list.
    func uninstall(confirmed shown: RemovalPlan, force: Bool) async {
        guard let runner, !isBusy else { return }
        guard let target = inventory.packages.first(where: { $0.id == shown.target }) else {
            showLog = true
            outcome = Outcome(title: "Uninstall", succeeded: false,
                              detail: "That package is no longer in the list, so nothing was run. Reload and try again.")
            return
        }
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
            if let selfID = plan.uninstallOrder.first(where: { graph.packages[$0].map(isRootBeerItself) ?? false }) {
                return Outcome(title: title, succeeded: false,
                               detail: "The plan includes \(graph.name(selfID)), which is the RootBeer you're running. Nothing was removed.")
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

    /// Runs one user-confirmed operation:
    /// 1. Marks the app busy (every action button is disabled; reloads are ignored).
    /// 2. Reloads, so the plan and the "before" list reflect what's installed now, not what was loaded
    ///    earlier. If that fails, nothing runs.
    /// 3. Runs `body`, reloads again, and compares: anything removed without an explicit uninstall is
    ///    flagged, new installs are listed, and `verify` can check the result. The report reflects what's
    ///    actually installed rather than what was planned.
    private func operation(
        _ title: String,
        _ body: () async -> Outcome,
        verify: ((inout Outcome, [Package]) -> Void)? = nil
    ) async {
        guard runner != nil, !isBusy else { return }
        activeOperation = title
        defer { activeOperation = nil; finishIfWindowClosed() }
        outcome = nil
        lastFailure = nil
        uninstalledThisOperation = []
        showLog = true
        appendLog(.info, "── \(title) ──\n")

        guard await loadInventory() else {
            let result = Outcome(title: title, succeeded: false,
                                 detail: "RootBeer couldn't read the installed packages, so nothing was run. \(loadError ?? "")")
            report(title, result)
            return
        }
        let before = Dictionary(inventory.packages.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var result = await body()

        if await loadInventory() {
            let after = Set(inventory.packages.map(\.id))
            let removed = Set(before.keys).subtracting(after)
            let unexpected = removed.subtracting(uninstalledThisOperation).compactMap { before[$0] }.sorted()
            let added = after.subtracting(before.keys).compactMap { id in inventory.packages.first { $0.id == id }?.name }.sorted()
            if !unexpected.isEmpty {
                result.warn("brew also removed \(unexpected.joined(separator: ", ")), which RootBeer didn't ask it to uninstall.")
            }
            if !added.isEmpty {
                result.detail += " Newly installed: \(added.joined(separator: ", "))."
            }
            if result.succeeded { verify?(&result, inventory.packages) }
        } else {
            result.warn("Couldn't reload the package list to verify the result.")
        }
        report(title, result)
    }

    private func report(_ title: String, _ result: Outcome) {
        outcome = result
        appendLog(result.succeeded ? .success : .failure, (result.succeeded ? "✓ " : "✗ ") + result.detail)
        RootBeerLog.info("\(title): \(result.succeeded ? "succeeded" : "FAILED") – \(result.detail)")
    }

    /// If the window was closed while brew was running, the app stayed open to let brew finish; quit now.
    private func finishIfWindowClosed() {
        if quitWhenOperationFinishes { NSApp.terminate(nil) }
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
            if result.succeeded, case .uninstall(let kind, let name) = action {
                uninstalledThisOperation.insert(Package.id(kind: kind, name: name))
            }
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
        if let runner, case let blocked = result.permissionBlockedKegs(prefix: runner.prefix), !blocked.isEmpty {
            return Outcome(
                title: title, succeeded: false,
                detail: prefix + "`\(action.commandLine)` couldn't delete \(blocked.joined(separator: ", ")) because some files in it belong to another user, usually root after something ran with sudo. Check the path is an old Homebrew version you expect, then run this in Terminal (it asks for your password) to give the files back to you, and try again:",
                terminalCommand: runner.permissionFixCommand(for: blocked)
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

    /// brew output is stored one line per entry, so the log view only lays out what's on screen even for
    /// long upgrades. A chunk that ends mid-line is continued by the next chunk of the same stream.
    private func appendLog(_ kind: LogEntry.Kind, _ text: String) {
        defer { logRevision += 1 }
        guard kind == .stdout || kind == .stderr else {
            addLogEntry(kind, text)
            return
        }
        var rest = Substring(text)
        if let last = log.indices.last, log[last].kind == kind, !log[last].text.hasSuffix("\n") {
            let end = rest.firstIndex(of: "\n").map { rest.index(after: $0) } ?? rest.endIndex
            log[last].text += rest[..<end]
            rest = rest[end...]
        }
        while !rest.isEmpty {
            let end = rest.firstIndex(of: "\n").map { rest.index(after: $0) } ?? rest.endIndex
            addLogEntry(kind, String(rest[..<end]))
            rest = rest[end...]
        }
    }

    private static let maxLogEntries = 5_000

    private func addLogEntry(_ kind: LogEntry.Kind, _ text: String) {
        nextLogID += 1
        log.append(LogEntry(id: nextLogID, kind: kind, text: text))
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries + 1)
            nextLogID += 1
            log.insert(LogEntry(id: nextLogID, kind: .info, text: "… earlier output trimmed …"), at: 0)
        }
    }

    /// The whole log as plain text, one entry per line.
    var logText: String {
        log.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }.joined()
    }

    func clearLog() {
        guard !isBusy else { return }
        log = []
        logRevision += 1
        outcome = nil
    }
}
