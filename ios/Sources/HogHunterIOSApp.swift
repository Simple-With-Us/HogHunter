import SwiftUI

@main
struct HogHunterIOSApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        WindowGroup {
            CompanionRootView(model: model)
                .preferredColorScheme(.light)
                .onOpenURL { url in
                    if url.scheme == "hoghunter" && url.host == "clean" {
                        model.showCleanDialogRequested = true
                    }
                }
        }
    }
}
