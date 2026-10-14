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
                    // A link may show the confirmation.  It never calls
                    // triggerRemoteClean.  Only the Run Safe Clean button does.
                    if CompanionDeepLink.classify(url).requestsCleanConfirmation {
                        model.requestCleanDialog()
                    }
                }
        }
    }
}
