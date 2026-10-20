import Foundation
import Testing
@testable import RootBeerCore

/// Fixtures are trimmed copies of real `brew info --installed --json=v2` / `brew outdated --json=v2`
/// output (Homebrew 7.0.9). The cask is anonymized as `example/tap/examplebar` with its JSON shape
/// unchanged, and install times are fixed.
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func inventory() throws -> Inventory {
    try Inventory.parse(info: fixture("info"), outdated: fixture("outdated"))
}

@Test func parsesFormulaeAndCasks() throws {
    let packages = try inventory().packages
    #expect(packages.map(\.name) == ["c-ares", "examplebar", "fastfetch", "libuv", "yyjson"])
    #expect(packages.filter { $0.kind == .formula }.count == 4)
    #expect(packages.filter { $0.kind == .cask }.count == 1)
}

@Test func parsesFormulaFields() throws {
    let fastfetch = try #require(try inventory().packages.first { $0.name == "fastfetch" })
    #expect(fastfetch.kind == .formula)
    #expect(fastfetch.installedOnRequest)
    #expect(!fastfetch.isDependency)
    #expect(fastfetch.dependencies == ["yyjson"])
    #expect(fastfetch.homepage == "https://github.com/fastfetch-cli/fastfetch")
    #expect(fastfetch.desc?.isEmpty == false)
    #expect(fastfetch.installedVersion == "2.55.1")
}

@Test func marksDependencies() throws {
    let yyjson = try #require(try inventory().packages.first { $0.name == "yyjson" })
    #expect(!yyjson.installedOnRequest)
    #expect(yyjson.isDependency)
}

@Test func mergesOutdatedVersions() throws {
    let packages = try inventory().packages
    let cares = try #require(packages.first { $0.name == "c-ares" })
    #expect(cares.isOutdated)
    #expect(cares.installedVersion == "1.34.6")
    #expect(cares.latestVersion == "1.34.8")
    let examplebar = try #require(packages.first { $0.name == "examplebar" })
    #expect(!examplebar.isOutdated)
    #expect(examplebar.latestVersion == nil)
}

@Test func parsesCaskFields() throws {
    let cask = try #require(try inventory().packages.first { $0.kind == .cask })
    #expect(cask.name == "examplebar")
    #expect(cask.fullName == "example/tap/examplebar")
    #expect(cask.displayName == "Examplebar")
    #expect(cask.installedVersion == "0.2.0")
    #expect(cask.installedOnRequest)
    #expect(!cask.isDependency)
    // Top-level `target` first, then the bare bundle name.
    #expect(cask.appNames == ["/Applications/Examplebar.app", "Examplebar.app"])
}

// Synthetic: this machine has no outdated casks and no `[src, {target:}]` app artifacts,
// so these shapes are hand-written from Homebrew's documented JSON format.
@Test func parsesSyntheticCaskShapes() throws {
    let info = Data("""
    {"formulae": [], "casks": [{
      "token": "foo", "full_token": "foo", "name": [], "desc": null, "homepage": null, "tap": "homebrew/cask",
      "version": "2.0", "installed": "1.0", "outdated": true, "depends_on": {"formula": ["homebrew/core/bar"]},
      "artifacts": [{"uninstall": [{"quit": "x"}]}, {"app": ["Foo.app", {"target": "Foo Pro.app"}]}, {"zap": []}]
    }]}
    """.utf8)
    let outdated = Data("""
    {"formulae": [], "casks": [{"name": "foo", "installed_versions": ["1.0"], "current_version": "2.0"}]}
    """.utf8)
    let foo = try #require(try Inventory.parse(info: info, outdated: outdated).packages.first)
    #expect(foo.displayName == "foo")
    #expect(foo.appNames == ["Foo.app", "Foo Pro.app"])
    #expect(foo.dependencies == ["bar"])
    #expect(foo.isOutdated)
    #expect(foo.latestVersion == "2.0")
}

@Test func rejectsMalformedJSON() {
    #expect(throws: (any Error).self) {
        try Inventory.parse(info: Data("{}".utf8), outdated: Data("{}".utf8))
    }
}

@Test func brewEnvironmentIsExplicit() {
    let env = BrewLocator.environment(for: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
    #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    #expect(env["HOMEBREW_NO_AUTOREMOVE"] == "1")
    #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:/opt/homebrew/sbin:") == true)
    // Built from an allowlist, so no inherited HOMEBREW_* variable can switch auto-update back on.
    #expect(env.keys.filter { $0.hasPrefix("HOMEBREW_") }.sorted()
        == ["HOMEBREW_NO_AUTOREMOVE", "HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_COLOR", "HOMEBREW_NO_EMOJI",
            "HOMEBREW_NO_ENV_HINTS", "HOMEBREW_NO_INSTALL_CLEANUP"])
}

@Test func mapsAutoremoveNamesToFormulae() throws {
    let inventory = try inventory()
    // Short names, a tap full name that doesn't exist here, and a cask token (never a formula).
    let ids = inventory.formulaIDs(named: ["yyjson", "user/tap/missing", "examplebar"])
    #expect(ids == ["formula:yyjson"])
}

@Test func tapFormulaeAreMatchedToOutdatedByFullName() throws {
    // `brew outdated --json=v2` names third-party formulae by full name (cmd/outdated.rb).
    let info = Data("""
    {"formulae": [{
      "name": "foo", "full_name": "user/tap/foo", "desc": null, "homepage": null, "tap": "user/tap",
      "versions": {"stable": "2.0"}, "dependencies": [], "outdated": true,
      "installed": [{"version": "1.0", "installed_on_request": true, "runtime_dependencies": []}]
    }], "casks": []}
    """.utf8)
    let outdated = Data("""
    {"formulae": [{"name": "user/tap/foo", "installed_versions": ["1.0"], "current_version": "2.0", "pinned": true}], "casks": []}
    """.utf8)
    let foo = try #require(try Inventory.parse(info: info, outdated: outdated).packages.first)
    #expect(foo.isOutdated)
    #expect(foo.latestVersion == "2.0")
    #expect(foo.isPinned)
}
