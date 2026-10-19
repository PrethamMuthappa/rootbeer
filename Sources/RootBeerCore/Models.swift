import Foundation

public enum PackageKind: String, Sendable, Hashable {
    case formula
    case cask
}

public struct Package: Identifiable, Hashable, Sendable {
    public var id: String { Package.id(kind: kind, name: name) }
    public static func id(kind: PackageKind, name: String) -> String { "\(kind.rawValue):\(name)" }

    public let kind: PackageKind
    public let name: String
    public let fullName: String
    public let displayName: String
    public let installedVersion: String
    public var latestVersion: String?
    public let desc: String?
    public let homepage: String?
    public let tap: String?
    /// Casks are always explicit installs.
    public let installedOnRequest: Bool
    /// Direct dependencies of the installed keg (formula names).
    public let dependencies: [String]
    /// Cask `.app` bundles: bare names ("Foo.app") or absolute target paths.
    public let appNames: [String]
    public var isOutdated: Bool
    /// Pinned packages show as outdated but `brew upgrade` skips them.
    public var isPinned: Bool = false

    public var isDependency: Bool { kind == .formula && !installedOnRequest }
}

public struct Inventory: Sendable {
    public var packages: [Package]

    public init(packages: [Package]) {
        self.packages = packages.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static let empty = Inventory(packages: [])

    public static func parse(info: Data, outdated: Data) throws -> Inventory {
        let raw = try JSONDecoder().decode(RawInfo.self, from: info)
        let late = try JSONDecoder().decode(RawOutdated.self, from: outdated)

        let outdatedFormulae = Dictionary(late.formulae.map { ($0.name, $0.current_version) }, uniquingKeysWith: { a, _ in a })
        let outdatedCasks = Dictionary(late.casks.map { ($0.name, $0.current_version) }, uniquingKeysWith: { a, _ in a })
        let pinned = Set(late.formulae.filter { $0.pinned == true }.map(\.name))

        // Dependencies may be listed by full name ("user/tap/foo"); normalize to short names.
        let shortName = Dictionary(raw.formulae.map { ($0.full_name, $0.name) }, uniquingKeysWith: { a, _ in a })
        func normalize(_ dep: String) -> String {
            shortName[dep] ?? String(dep.split(separator: "/").last ?? Substring(dep))
        }

        let formulae = raw.formulae.map { f -> Package in
            let keg = f.installed.last
            let directRuntime = keg?.runtime_dependencies?.filter { $0.declared_directly ?? true }.map(\.full_name)
            let latest = outdatedFormulae[f.name] ?? nil
            return Package(
                kind: .formula,
                name: f.name,
                fullName: f.full_name,
                displayName: f.name,
                installedVersion: keg?.version ?? f.versions.stable ?? "?",
                latestVersion: latest,
                desc: f.desc,
                homepage: f.homepage,
                tap: f.tap,
                installedOnRequest: keg?.installed_on_request ?? true,
                dependencies: (directRuntime ?? f.dependencies).map(normalize),
                appNames: [],
                isOutdated: outdatedFormulae.keys.contains(f.name),
                isPinned: pinned.contains(f.name)
            )
        }

        let casks = raw.casks.map { c -> Package in
            let latest = outdatedCasks[c.token] ?? nil
            return Package(
                kind: .cask,
                name: c.token,
                fullName: c.full_token,
                displayName: c.name.first ?? c.token,
                installedVersion: c.installed ?? c.version,
                latestVersion: latest,
                desc: c.desc,
                homepage: c.homepage,
                tap: c.tap,
                installedOnRequest: true,
                dependencies: (c.depends_on?.formula ?? []).map(normalize),
                appNames: c.artifacts.flatMap(\.apps),
                isOutdated: outdatedCasks.keys.contains(c.token)
            )
        }

        return Inventory(packages: formulae + casks)
    }
}

// MARK: - Raw JSON shapes (`brew info --installed --json=v2`, `brew outdated --json=v2`)

struct RawInfo: Decodable {
    let formulae: [RawFormula]
    let casks: [RawCask]
}

struct RawFormula: Decodable {
    struct Versions: Decodable { let stable: String? }
    struct Keg: Decodable {
        let version: String
        let installed_on_request: Bool?
        let runtime_dependencies: [RuntimeDependency]?
    }
    struct RuntimeDependency: Decodable {
        let full_name: String
        let declared_directly: Bool?
    }

    let name: String
    let full_name: String
    let desc: String?
    let homepage: String?
    let tap: String?
    let versions: Versions
    let dependencies: [String]
    let installed: [Keg]
    let outdated: Bool?
}

struct RawCask: Decodable {
    struct DependsOn: Decodable { let formula: [String]? }

    let token: String
    let full_token: String
    let name: [String]
    let desc: String?
    let homepage: String?
    let tap: String?
    let version: String
    let installed: String?
    let outdated: Bool?
    let depends_on: DependsOn?
    let artifacts: [RawArtifact]
}

/// One entry of a cask's heterogeneous `artifacts` array. Only `app` matters here:
///   {"app": ["Foo.app"], "target": "/Applications/Foo.app"}
///   {"app": ["Foo.app", {"target": "Bar.app"}]}
struct RawArtifact: Decodable {
    let apps: [String]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Key.self),
              let values = try? container.decode([JSONValue].self, forKey: Key(stringValue: "app"))
        else {
            apps = []
            return
        }
        let target = try? container.decode(String.self, forKey: Key(stringValue: "target"))
        var names: [String] = []
        for value in values {
            switch value {
            case .string(let name): names.append(name)
            case .object(let options): if case .string(let t)? = options["target"] { names.append(t) }
            default: break
            }
        }
        // A top-level target is the real installed location; prefer it.
        apps = target.map { [$0] + names } ?? names
    }
}

struct RawOutdated: Decodable {
    struct Entry: Decodable {
        let name: String
        let current_version: String?
        let pinned: Bool?
    }
    let formulae: [Entry]
    let casks: [Entry]
}

/// Minimal JSON value, for the untyped parts of the artifacts array.
enum JSONValue: Decodable {
    case string(String)
    case object([String: JSONValue])
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .other
        }
    }
}
