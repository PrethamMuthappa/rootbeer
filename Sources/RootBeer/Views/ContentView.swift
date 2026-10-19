import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } content: {
            PackageGridView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 560)
        } detail: {
            DetailView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search packages")
        .navigationTitle("RootBeer")
        .toolbar {
            ToolbarItem {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.reload() } } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload installed packages")
                }
            }
        }
    }
}
