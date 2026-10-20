import Foundation
import Testing
@testable import RootBeerCore

private func formula(_ name: String, onRequest: Bool = false, deps: [String] = []) -> Package {
    Package(kind: .formula, name: name, fullName: name, displayName: name, installedVersion: "1",
            desc: nil, homepage: nil, tap: nil, installedOnRequest: onRequest,
            dependencies: deps, appNames: [], isOutdated: false)
}

private func cask(_ name: String, deps: [String] = []) -> Package {
    Package(kind: .cask, name: name, fullName: name, displayName: name, installedVersion: "1",
            desc: nil, homepage: nil, tap: nil, installedOnRequest: true,
            dependencies: deps, appNames: [], isOutdated: false)
}

private func f(_ name: String) -> Package.ID { "formula:\(name)" }
private func names(_ ids: [Package.ID]) -> [String] { ids.map { String($0.split(separator: ":").last!) } }

private func plan(
    _ target: String,
    _ packages: [Package],
    include: [String] = [],
    exclude: [String] = []
) -> RemovalPlan {
    RemovalPlanner.plan(
        target: f(target),
        graph: DependencyGraph(packages),
        includedDependents: Set(include.map(f)),
        excludedDependencies: Set(exclude.map(f))
    )
}

@Test func removesExclusiveDependencies() {
    let p = plan("app", [formula("app", onRequest: true, deps: ["lib"]), formula("lib")])
    #expect(names(p.roots) == ["app"])
    #expect(names(p.dependencies) == ["lib"])
    #expect(!p.isBlocked)
}

@Test func keepsDependencySharedWithAnotherPackage() {
    let p = plan("app", [
        formula("app", onRequest: true, deps: ["lib", "shared"]),
        formula("other", onRequest: true, deps: ["shared"]),
        formula("lib"),
        formula("shared"),
    ])
    #expect(names(p.dependencies) == ["lib"])
}

@Test func keepsDependencyInstalledOnRequest() {
    let p = plan("app", [formula("app", onRequest: true, deps: ["tool"]), formula("tool", onRequest: true)])
    #expect(p.dependencies.isEmpty)
}

@Test func followsTransitiveChainAndOrdersDependentsFirst() {
    // app → a → b → c, plus app → c directly.
    let p = plan("app", [
        formula("app", onRequest: true, deps: ["a", "c"]),
        formula("a", deps: ["b"]),
        formula("b", deps: ["c"]),
        formula("c"),
    ])
    #expect(names(p.dependencies) == ["a", "b", "c"])
    #expect(names(p.uninstallOrder) == ["app", "a", "b", "c"])
}

@Test func diamondIsRemovedOnlyWhenBothSidesGo() {
    // app → left → base and app → right → base.
    let packages = [
        formula("app", onRequest: true, deps: ["left", "right"]),
        formula("left", deps: ["base"]),
        formula("right", deps: ["base"]),
        formula("base"),
    ]
    #expect(Set(names(plan("app", packages).dependencies)) == ["left", "right", "base"])
    #expect(names(plan("app", packages).dependencies).last == "base")
    // Unticking `right` keeps it, so `base` (still needed by `right`) stays too.
    let partial = plan("app", packages, exclude: ["right"])
    #expect(names(partial.dependencies) == ["left"])
    #expect(Set(names(partial.candidateDependencies)) == ["left", "right", "base"])
    #expect(partial.excludedDependencies == [f("right")])
}

// MARK: Dependents and Force

@Test func dependentsAreListedButNeverAddedAutomatically() {
    let packages = [
        formula("lib", onRequest: true, deps: ["zlib"]),
        formula("app", onRequest: true, deps: ["lib"]),
        formula("zlib"),
    ]
    let p = plan("lib", packages)
    #expect(names(p.candidateDependents) == ["app"])
    #expect(names(p.roots) == ["lib"])
    #expect(!p.uninstallOrder.contains(f("app")))
    #expect(names(p.blockingDependents) == ["app"])
    #expect(p.isBlocked)
    // zlib is only used by lib, which is being removed.
    #expect(names(p.dependencies) == ["zlib"])
}

@Test func blockedPlanIsIdenticalWhateverForceWouldBe() {
    // Force lives in the UI and isn't a planner input, so it can't change what gets removed.
    let packages = [formula("lib", onRequest: true), formula("app", onRequest: true, deps: ["lib"])]
    #expect(plan("lib", packages).uninstallOrder == [f("lib")])
}

@Test func tickedDependentIsRemovedFirstAndClearsBlock() {
    let packages = [
        formula("lib", onRequest: true),
        formula("app", onRequest: true, deps: ["lib", "applib"]),
        formula("applib"),
    ]
    let p = plan("lib", packages, include: ["app"])
    #expect(names(p.roots) == ["app", "lib"])
    #expect(names(p.dependencies) == ["applib"])
    #expect(!p.isBlocked)
}

@Test func onlyTickedDependentsAreRemoved() {
    // app1 and app2 both use lib; ticking only app1 leaves app2 blocking.
    let packages = [
        formula("lib", onRequest: true),
        formula("app1", onRequest: true, deps: ["lib"]),
        formula("app2", onRequest: true, deps: ["lib"]),
    ]
    let p = plan("lib", packages, include: ["app1"])
    #expect(names(p.roots) == ["app1", "lib"])
    #expect(names(p.blockingDependents) == ["app2"])
}

@Test func indirectDependentsAreOfferedAndOrdered() {
    // top → mid → lib. Ticking only top leaves mid blocking; ticking both orders top, mid, lib.
    let packages = [
        formula("lib", onRequest: true),
        formula("mid", onRequest: true, deps: ["lib"]),
        formula("top", onRequest: true, deps: ["mid"]),
    ]
    #expect(names(plan("lib", packages).candidateDependents) == ["mid", "top"])
    #expect(names(plan("lib", packages, include: ["top"]).blockingDependents) == ["mid"])
    #expect(names(plan("lib", packages, include: ["top", "mid"]).roots) == ["top", "mid", "lib"])
}

@Test func ignoresIncludedPackagesThatAreNotDependents() {
    let packages = [formula("lib", onRequest: true), formula("unrelated", onRequest: true)]
    #expect(names(plan("lib", packages, include: ["unrelated"]).roots) == ["lib"])
}

@Test func caskDependentBlocksFormula() {
    let packages = [formula("lib"), cask("viewer", deps: ["lib"])]
    let p = plan("lib", packages)
    #expect(p.blockingDependents == ["cask:viewer"])
}

@Test func dependencyAlsoNeededByBlockingDependentIsKept() {
    // lib → zlib, app → lib and app → zlib. app stays, so zlib must stay.
    let packages = [
        formula("lib", onRequest: true, deps: ["zlib"]),
        formula("app", onRequest: true, deps: ["lib", "zlib"]),
        formula("zlib"),
    ]
    #expect(plan("lib", packages).dependencies.isEmpty)
}

@Test func plansAgainstRealFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "info", withExtension: "json", subdirectory: "Fixtures"))
    let outdated = try #require(Bundle.module.url(forResource: "outdated", withExtension: "json", subdirectory: "Fixtures"))
    let inventory = try Inventory.parse(info: Data(contentsOf: url), outdated: Data(contentsOf: outdated))
    let graph = DependencyGraph(inventory.packages)
    // fastfetch was installed on request and is the only user of yyjson.
    let p = RemovalPlanner.plan(target: f("fastfetch"), graph: graph)
    #expect(names(p.dependencies) == ["yyjson"])
    #expect(!p.isBlocked)
    // yyjson itself is blocked by fastfetch.
    #expect(names(RemovalPlanner.plan(target: f("yyjson"), graph: graph).blockingDependents) == ["fastfetch"])
}

// MARK: Brew command construction (no brew is run)

@Test func actionArgumentsAreExact() {
    #expect(BrewAction.update.arguments == ["update"])
    #expect(BrewAction.upgradeAll.arguments == ["upgrade"])
    #expect(BrewAction.upgrade(.formula, "wget").arguments == ["upgrade", "--formula", "wget"])
    #expect(BrewAction.upgrade(.cask, "firefox").arguments == ["upgrade", "--cask", "firefox"])
    #expect(BrewAction.uninstall(.formula, "wget").arguments == ["uninstall", "--formula", "wget"])
    #expect(BrewAction.uninstall(.cask, "firefox").arguments == ["uninstall", "--cask", "firefox"])
    #expect(BrewAction.cleanup.arguments == ["cleanup"])
}

@Test func refusesInvalidPackageNames() async {
    // A missing brew would also throw (launchFailed), so check for the specific refusal.
    let runner = BrewRunner(brewURL: URL(fileURLWithPath: "/nonexistent/brew"))
    let bad = ["--force", "", "-x", "a b", "a;rm", "a/b", "caf\u{E9}", "$(id)", "a\nb", String(repeating: "a", count: 201)]
    for name in bad {
        for action in [BrewAction.uninstall(.formula, name), .upgrade(.cask, name)] {
            do {
                _ = try await runner.perform(action)
                Issue.record("expected \(action) to be refused")
            } catch BrewError.invalidPackageName {
            } catch {
                Issue.record("expected invalidPackageName for \(name.debugDescription), got \(error)")
            }
        }
    }
    do {
        _ = try await runner.installedUses(of: "-x")
        Issue.record("expected installedUses to refuse a flag-like name")
    } catch BrewError.invalidPackageName {
    } catch {
        Issue.record("expected invalidPackageName, got \(error)")
    }
}

@Test func acceptsRealPackageNames() {
    for name in ["jq", "node@24", "python@3.15", "c-ares", "libnghttp2", "gtk+3", "font-fira_code", "7zip"] {
        #expect(BrewText.isValidPackageName(name), "\(name)")
    }
}

@Test func parsesAutoremoveDryRun() {
    // Format from Homebrew's cleanup.rb: header via oh1, then full names, one per line.
    let output = "==> Would autoremove 3 unneeded formulae:\nlibpng\nuser/tap/foo\nzstd\n"
    #expect(BrewRunner.parseAutoremoveDryRun(output) == ["libpng", "user/tap/foo", "zstd"])
    #expect(BrewRunner.parseAutoremoveDryRun("") == [])
}

@Test func detectsPasswordFailures() {
    let sudo = BrewResult(arguments: [], exitCode: 1, stdout: "",
                          stderr: "Error: Failure while executing\nsudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\n")
    #expect(sudo.needsAdminPassword)
    let refused = BrewResult(arguments: [], exitCode: 1, stdout: "",
                             stderr: "Error: Refusing to uninstall /opt/homebrew/Cellar/lib\nbecause it is required by app, which is currently installed.\n")
    #expect(!refused.needsAdminPassword)
    // Package output that merely mentions askpass or sudo isn't sudo asking for a password.
    let mention = BrewResult(arguments: [], exitCode: 1, stdout: "sudo: a password is required\n",
                             stderr: "Error: ssh-askpass failed to build\nWarning: run with sudo: a terminal is required\n")
    #expect(!mention.needsAdminPassword)
}

@Test func terminalCommandCarriesSafetySettings() {
    let runner = BrewRunner(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
    #expect(runner.terminalCommand(for: .uninstall(.cask, "foo")) ==
        "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1 /opt/homebrew/bin/brew uninstall --cask foo")
    // The suggested command must carry every setting RootBeer's own brew processes use.
    for variable in BrewLocator.safetyVariables {
        #expect(runner.terminalCommand(for: .cleanup).contains("\(variable.name)=\(variable.value)"))
    }
}

@Test func shellQuotingIsConservative() {
    #expect(BrewRunner.shellQuoted("/opt/homebrew/Cellar/python@3.14/3.14.7") == "/opt/homebrew/Cellar/python@3.14/3.14.7")
    #expect(BrewRunner.shellQuoted("it's") == #"'it'\''s'"#)
    #expect(BrewRunner.shellQuoted("=rm") == "'=rm'")            // zsh would expand a leading =
    #expect(BrewRunner.shellQuoted("~root") == "'~root'")
    #expect(BrewRunner.shellQuoted("caf\u{E9}") == "'caf\u{E9}'") // non-ASCII is always quoted
    #expect(BrewRunner.shellQuoted("") == "''")
}

// Messages from Homebrew's cmd/cleanup.rb and keg.rb. The cleanup one matches a real failure on this
// machine: root-owned __pycache__ folders left in an old python@3.14 keg.
private func allDirectories(_: String) -> Bool { true }

@Test func findsPermissionBlockedKegsFromCleanup() {
    let result = BrewResult(arguments: ["cleanup"], exitCode: 1, stdout: "", stderr: """
        Warning: Permission denied @ dir_s_rmdir - /opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/x/__pycache__
        Error: Could not cleanup old kegs! Fix your permissions on:
          /opt/homebrew/Cellar/python@3.14/3.14.7
          /opt/homebrew/Cellar/foo/1.0
        """)
    #expect(result.permissionBlockedKegs(prefix: "/opt/homebrew", isRealDirectory: allDirectories) == [
        "/opt/homebrew/Cellar/python@3.14/3.14.7", "/opt/homebrew/Cellar/foo/1.0",
    ])
    #expect(!result.needsAdminPassword)
}

@Test func findsPermissionBlockedKegsFromUninstall() {
    let result = BrewResult(arguments: ["uninstall"], exitCode: 1, stdout: "", stderr: """
        Error: Could not remove jq keg! Do so manually:
          sudo rm -rf /opt/homebrew/Cellar/jq/1.8.1
        """)
    #expect(result.permissionBlockedKegs(prefix: "/opt/homebrew", isRealDirectory: allDirectories) == ["/opt/homebrew/Cellar/jq/1.8.1"])
}

@Test func onlyTrustsBrewsOwnErrorLineOnStderr() {
    let paths = "  /opt/homebrew/Cellar/jq/1.8.1\n"
    // On stdout (package output), or on stderr without brew's "Error: " line, it's ignored.
    let onStdout = BrewResult(arguments: [], exitCode: 1,
                              stdout: "Error: Could not cleanup old kegs! Fix your permissions on:\n" + paths, stderr: "")
    let bare = BrewResult(arguments: [], exitCode: 1, stdout: "", stderr: "Fix your permissions on:\n" + paths)
    let late = BrewResult(arguments: [], exitCode: 1, stdout: "",
                          stderr: "Error: Could not cleanup old kegs! Fix your permissions on:\nsomething else\n" + paths)
    for result in [onStdout, bare, late] {
        #expect(result.permissionBlockedKegs(prefix: "/opt/homebrew", isRealDirectory: allDirectories).isEmpty)
    }
}

@Test func rejectsAnythingButAKegPath() {
    let candidates = [
        "/etc", "/opt/homebrew/../../etc", "/opt/homebrewevil/Cellar/a/1", "relative/path",
        "/opt/homebrew/Cellar/a", "/opt/homebrew/Cellar/a/1/sub", "/opt/homebrew/Cellar/a/..",
        "/opt/homebrew/Cellar//1", "/opt/homebrew/lib/node_modules/x", "/opt/homebrew/Cellar/a/1/",
        "/opt/homebrew/Cellar/pyth\u{43E}n/1",      // Cyrillic o
        "/opt/homebrew/Cellar/a/1\u{202E}",          // right-to-left override
        "/opt/homebrew/Cellar/a/1\u{1B}[201~",        // escape sequence
        "/opt/homebrew/Cellar/a b/1",
    ]
    let result = BrewResult(arguments: [], exitCode: 1, stdout: "",
                            stderr: candidates.map { "Error: Could not cleanup old kegs! Fix your permissions on:\n  \($0)" }.joined(separator: "\n"))
    #expect(result.permissionBlockedKegs(prefix: "/opt/homebrew", isRealDirectory: allDirectories).isEmpty)
}

@Test func rejectsKegPathsThroughSymlinks() throws {
    // Real filesystem: <tmp>/prefix/Cellar/evil/1.0 is a symlink to "/", and .../good/1.0 is a directory.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rootbeer-\(UUID().uuidString)")
    let prefix = root.appendingPathComponent("prefix").path
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(atPath: prefix + "/Cellar/good/1.0", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: prefix + "/Cellar/evil", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: prefix + "/Cellar/evil/1.0", withDestinationPath: "/")
    try FileManager.default.createSymbolicLink(atPath: prefix + "/Cellar/linked", withDestinationPath: prefix + "/Cellar/good")

    let stderr = """
        Error: Could not cleanup old kegs! Fix your permissions on:
          \(prefix)/Cellar/evil/1.0
          \(prefix)/Cellar/linked/1.0
          \(prefix)/Cellar/good/1.0
        """
    let result = BrewResult(arguments: [], exitCode: 1, stdout: "", stderr: stderr)
    #expect(result.permissionBlockedKegs(prefix: prefix) == ["\(prefix)/Cellar/good/1.0"])
}

@Test func permissionFixCommandUsesSystemTools() {
    let runner = BrewRunner(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
    #expect(runner.prefix == "/opt/homebrew")
    #expect(runner.permissionFixCommand(for: ["/opt/homebrew/Cellar/python@3.14/3.14.7"], user: "user")
        == "/usr/bin/sudo /usr/sbin/chown -R -P user:admin /opt/homebrew/Cellar/python@3.14/3.14.7")
}

@Test func streamsOnlyCompleteUTF8Characters() {
    let bytes = Data("a\u{E9}\u{1F37A}".utf8)            // 1 + 2 + 4 bytes
    #expect(BrewText.completeUTF8Length(bytes) == bytes.count)
    #expect(BrewText.completeUTF8Length(bytes.prefix(2)) == 1)      // é cut after its first byte
    #expect(BrewText.completeUTF8Length(bytes.prefix(5)) == 3)      // 🍺 cut after two of four bytes
    #expect(BrewText.completeUTF8Length(Data()) == 0)
}

@Test func tiedNamesSortTheSameEveryTime() {
    // A formula and a cask with the same name both depend on lib.
    let packages = [
        formula("lib", onRequest: true),
        formula("dup", onRequest: true, deps: ["lib"]),
        cask("dup", deps: ["lib"]),
    ]
    let first = plan("lib", packages)
    #expect(first.candidateDependents == ["cask:dup", "formula:dup"])
    #expect(plan("lib", packages) == first)
}
