import WidgetKit
import SwiftUI

@main
struct HogHunterWidgets: Widget {
    let kind: String = "HogHunterWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HogHunterWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hog Hunter")
        .description("Track Mac CPU and RAM.  Clean asks before anything is removed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
