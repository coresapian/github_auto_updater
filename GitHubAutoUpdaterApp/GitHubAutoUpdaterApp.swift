import SwiftUI

@main
struct GitHubAutoUpdaterApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.refresh()
                }
                .task(id: viewModel.refreshInterval) {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(viewModel.refreshInterval))
                        if Task.isCancelled { break }
                        await viewModel.refresh()
                    }
                }
        }
    }
}
