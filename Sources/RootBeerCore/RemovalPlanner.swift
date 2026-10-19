import Foundation

/// The installed dependency graph. Nodes are `Package.ID`s, so a formula and a cask can share a name.
public struct DependencyGraph: Sendable {
    public let packages: [Package.ID: Package]
    /// id → installed packages it depends on directly.
    let dependencies: [Package.ID: Set<Package.ID>]
    /// id → installed packages that depend on it directly.
    let dependents: [Package.ID: Set<Package.ID>]

    public init(_ packages: [Package]) {
        var byID: [Package.ID: Package] = [:]
        var formulaByName: [String: Package.ID] = [:]
        for package in packages {
            byID[package.id] = package
            if package.kind == .formula {
                formulaByName[package.name] = package.id
                formulaByName[package.fullName] = package.id
            }
        }
        var dependencies: [Package.ID: Set<Package.ID>] = [:]
        var dependents: [Package.ID: Set<Package.ID>] = [:]
        for package in packages {
            let deps = Set(package.dependencies.compactMap { formulaByName[$0] }).subtracting([package.id])
            dependencies[package.id] = deps
            for dep in deps { dependents[dep, default: []].insert(package.id) }
        }
        self.packages = byID
        self.dependencies = dependencies
        self.dependents = dependents
    }

    public func directDependents(of id: Package.ID) -> Set<Package.ID> { dependents[id] ?? [] }

    /// Everything installed that depends on `id`, directly or through other packages.
    public func allDependents(of id: Package.ID) -> Set<Package.ID> {
        var seen: Set<Package.ID> = []
        var queue = Array(directDependents(of: id))
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            queue.append(contentsOf: directDependents(of: next))
        }
        seen.remove(id)
        return seen
    }

    public func name(_ id: Package.ID) -> String { packages[id]?.name ?? id }
}

public struct RemovalPlan: Sendable, Equatable {
    public let target: Package.ID
    /// Installed packages that depend on the target, directly or indirectly. Shown as opt-in rows;
    /// only the ones in `roots` will be removed.
    public let candidateDependents: [Package.ID]
    /// The target plus the dependents the user ticked, in uninstall order.
    public let roots: [Package.ID]
    /// Dependencies that would be removable if none were unticked. One checkbox row each.
    public let candidateDependencies: [Package.ID]
    /// Dependencies the user unticked.
    public let excludedDependencies: Set<Package.ID>
    /// Dependencies that will be removed, in uninstall order.
    public let dependencies: [Package.ID]
    /// Installed packages that stay installed but depend on something being removed.
    public let blockingDependents: [Package.ID]

    public var isBlocked: Bool { !blockingDependents.isEmpty }
    /// Everything that will be uninstalled, in order.
    public var uninstallOrder: [Package.ID] { roots + dependencies }
}

public enum RemovalPlanner {
    /// Computes what uninstalling `target` removes.
    ///
    /// The removal set starts with the target and any `includedDependents`. A dependency joins it when
    /// it wasn't installed on request, wasn't unticked, and every installed package that depends on it
    /// is already in the set. This repeats until nothing changes. Dependents are never added
    /// automatically; anything left depending on the set is reported in `blockingDependents`.
    public static func plan(
        target: Package.ID,
        graph: DependencyGraph,
        includedDependents: Set<Package.ID> = [],
        excludedDependencies: Set<Package.ID> = []
    ) -> RemovalPlan {
        let candidateDependents = graph.allDependents(of: target)
        let roots = includedDependents.intersection(candidateDependents).union([target])

        let candidates = removableDependencies(roots: roots, graph: graph, excluding: [])
        let excluded = excludedDependencies.intersection(candidates)
        let dependencies = removableDependencies(roots: roots, graph: graph, excluding: excluded)

        let removalSet = roots.union(dependencies)
        let blockers = removalSet
            .reduce(into: Set<Package.ID>()) { $0.formUnion(graph.directDependents(of: $1)) }
            .subtracting(removalSet)

        return RemovalPlan(
            target: target,
            candidateDependents: sortedByName(candidateDependents, graph),
            roots: uninstallOrder(roots, graph),
            candidateDependencies: sortedByName(candidates, graph),
            excludedDependencies: excluded,
            dependencies: uninstallOrder(dependencies, graph),
            blockingDependents: sortedByName(blockers, graph)
        )
    }

    private static func removableDependencies(
        roots: Set<Package.ID>,
        graph: DependencyGraph,
        excluding excluded: Set<Package.ID>
    ) -> Set<Package.ID> {
        var set = roots
        var changed = true
        while changed {
            changed = false
            for member in set {
                for dep in graph.dependencies[member] ?? [] where !set.contains(dep) && !excluded.contains(dep) {
                    guard let package = graph.packages[dep],
                          package.kind == .formula,
                          !package.installedOnRequest,
                          graph.directDependents(of: dep).isSubset(of: set)
                    else { continue }
                    set.insert(dep)
                    changed = true
                }
            }
        }
        return set.subtracting(roots)
    }

    /// Orders `ids` so each package comes before anything it depends on, directly or indirectly,
    /// because brew refuses to uninstall a package while something installed still needs it.
    static func uninstallOrder(_ ids: Set<Package.ID>, _ graph: DependencyGraph) -> [Package.ID] {
        let dependentsWithin = Dictionary(uniqueKeysWithValues: ids.map { ($0, graph.allDependents(of: $0).intersection(ids)) })
        var remaining = ids
        var order: [Package.ID] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { dependentsWithin[$0]!.isDisjoint(with: remaining) }
            // A cycle shouldn't happen in Homebrew; fall back to name order rather than loop forever.
            let batch = ready.isEmpty ? remaining : ready
            for id in sortedByName(batch, graph) {
                order.append(id)
                remaining.remove(id)
            }
        }
        return order
    }

    private static func sortedByName(_ ids: Set<Package.ID>, _ graph: DependencyGraph) -> [Package.ID] {
        ids.sorted { graph.name($0).localizedStandardCompare(graph.name($1)) == .orderedAscending }
    }
}
