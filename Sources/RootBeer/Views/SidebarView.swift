import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(SidebarItem.allCases, selection: $model.sidebarSelection) { item in
            Label(item.rawValue, systemImage: item.symbol)
                .badge(model.count(for: item))
                .tag(item)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        .safeAreaInset(edge: .bottom) {
            Link(destination: RootBeerLinks.support) {
                Label("Buy me a coffee", systemImage: "cup.and.saucer")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("RootBeer is free. If it saves you time, you can support it at buymeacoffee.com/pretham")
        }
    }
}
