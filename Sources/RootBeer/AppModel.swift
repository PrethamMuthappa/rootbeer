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

@MainActor
@Observable
final class AppModel {
    private(set) var inventory = Inventory.empty
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var uses: [String: UsesState] = [:]

    var sidebarSelection: SidebarItem? = .all
    var searchText = ""
    var selectedID: Package.ID?

    private let runner: BrewRunner?

    init() {
        do {
            runner = try BrewRunner.located()
        } catch {
            runner = nil
            loadError = error.localizedDescription
        }
    }

    var selectedPackage: Package? {
        inventory.packages.first { $0.id == selectedID }
    }

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

    func reload() async {
        guard let runner, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await runner.installedInfoJSON()
            let outdated = try await runner.outdatedJSON()
            inventory = try await Task.detached { try Inventory.parse(info: info, outdated: outdated) }.value
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
}
