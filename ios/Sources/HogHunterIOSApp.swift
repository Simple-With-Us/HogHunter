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
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    // A link may show the confirmation.  It never calls
                    // triggerRemoteClean.  Only the Run Safe Clean button does.
                    if CompanionDeepLink.classify(url).requestsCleanConfirmation {
                        model.requestCleanDialog()
                    }
                }
        }
    }

    /// The Mac's appearance, so this iPhone never looks like a different app
    /// from the Mac it watches.  "System" leaves the phone on its own setting,
    /// and a phone with no Mac yet keeps the light default.
    private var colorScheme: ColorScheme? {
        guard let appearance = model.snapshot?.settings?.appearance else { return .light }
        switch appearance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
