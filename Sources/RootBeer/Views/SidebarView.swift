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
    }
}
