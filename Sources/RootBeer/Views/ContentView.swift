import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } content: {
                PackageGridView()
                    .navigationSplitViewColumnWidth(min: 360, ideal: 560)
            } detail: {
                DetailView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            }
            if model.showLog {
                Divider()
                LogPanel()
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search packages")
        .navigationTitle("RootBeer")
        .toolbar { toolbar }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .upgradeAll(let packages, let snapshot): UpgradeAllSheet(packages: packages, snapshot: snapshot)
            case .upgrade(let package, let snapshot): UpgradeSheet(package: package, snapshot: snapshot)
            case .uninstallCask(let cask): CaskUninstallSheet(cask: cask)
            case .uninstallFormula(let draft): UninstallSheet(draft: draft)
            case .cleanup(let output, let hasWork): CleanupSheet(dryRunOutput: output, hasWork: hasWork)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await model.updateHomebrew() } } label: {
                Label("Update Homebrew", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Run brew update to refresh Homebrew's package data")
            .disabled(model.isBusy)

            Button { model.requestUpgradeAll() } label: {
                Label("Upgrade All", systemImage: "arrow.up.circle")
            }
            .help("Review and upgrade every outdated package")
            .disabled(model.isBusy || model.outdatedPackages.isEmpty)

            Button { Task { await model.requestCleanup() } } label: {
                Label("Cleanup", systemImage: "trash")
            }
            .help("Preview and run brew cleanup")
            .disabled(model.isBusy)

            Button { Task { await model.reload() } } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Reload installed packages")
            .disabled(model.isBusy)
        }

        ToolbarItem {
            Button { model.showLog.toggle() } label: {
                Label("Log", systemImage: "text.alignleft")
            }
            .help(model.showLog ? "Hide log" : "Show log")
        }
    }
}
