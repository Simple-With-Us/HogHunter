import SwiftUI

@main
struct HogHunterIOSApp: App {
    @State private var model = CompanionModel()

    init() {
        // Sentry first, so early-launch crashes are captured.  A build
        // without a baked-in DSN is a silent no-op.  See SentryTelemetry.
        SentryTelemetry.start()
    }

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
