import AppIntents
import WidgetKit
import SwiftUI

@main
struct HogHunterWidgets: Widget {
    let kind: String = "HogHunterWidgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectHostIntent.self, provider: Provider()) { entry in
            HogHunterWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hog Hunter")
        .description("Track your Mac, your server, or both.\u{00A0} Clean asks before anything is removed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
