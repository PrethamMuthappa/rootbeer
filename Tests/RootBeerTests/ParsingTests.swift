import Foundation
import Testing
@testable import RootBeerCore

/// Fixtures are trimmed copies of real `brew info --installed --json=v2` / `brew outdated --json=v2`
/// output from this machine (Homebrew 7.0.9).
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func inventory() throws -> Inventory {
    try Inventory.parse(info: fixture("info"), outdated: fixture("outdated"))
}

@Test func parsesFormulaeAndCasks() throws {
    let packages = try inventory().packages
    #expect(packages.map(\.name) == ["c-ares", "claudebar", "fastfetch", "libuv", "yyjson"])
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
    let claudebar = try #require(packages.first { $0.name == "claudebar" })
    #expect(!claudebar.isOutdated)
    #expect(claudebar.latestVersion == nil)
}

@Test func parsesCaskFields() throws {
    let cask = try #require(try inventory().packages.first { $0.kind == .cask })
    #expect(cask.name == "claudebar")
    #expect(cask.fullName == "gautham-v/tap/claudebar")
    #expect(cask.displayName == "Claudebar")
    #expect(cask.installedVersion == "0.2.0")
    #expect(cask.installedOnRequest)
    #expect(!cask.isDependency)
    // Top-level `target` first, then the bare bundle name.
    #expect(cask.appNames == ["/Applications/Claudebar.app", "Claudebar.app"])
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
