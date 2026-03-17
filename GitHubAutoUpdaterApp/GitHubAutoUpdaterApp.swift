import SwiftUI

@main
struct GitHubAutoUpdaterApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
        }
        .backgroundTask(.appRefresh(AppViewModel.backgroundTaskIdentifier)) {
            await viewModel.performBackgroundRefresh()
        }
    }
}
