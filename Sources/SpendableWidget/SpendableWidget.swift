import SwiftUI
import WidgetKit

// Milestone 1 stub. Its only job is to prove that a sandboxed WidgetKit extension signed by the
// free Personal Team is discovered by the system and can read the shared App Group container.
// Milestone 8 replaces it with the real small and medium widgets over the summary file.
// It links neither GRDB nor networking: the widget never touches the database.

struct SpikeEntry: TimelineEntry {
    let date: Date
    let text: String
}

struct SpikeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: .now, text: "Spendable")
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SpikeEntry) -> Void) {
        completion(SpikeEntry(date: .now, text: readSentinel()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SpikeEntry>) -> Void) {
        completion(Timeline(entries: [SpikeEntry(date: .now, text: readSentinel())], policy: .never))
    }

    private func readSentinel() -> String {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "UW2KV7XB66.spendable") else {
            return "Spendable: no container"
        }
        let sentinel = container.appendingPathComponent("spike.txt")
        if (try? String(contentsOf: sentinel, encoding: .utf8)) != nil {
            return "Spendable: container OK"
        }
        return "Spendable: sentinel missing"
    }
}

struct SpendableWidgetEntryView: View {
    var entry: SpikeEntry

    var body: some View {
        Text(entry.text)
            .font(.headline)
            .multilineTextAlignment(.center)
            .containerBackground(.background, for: .widget)
    }
}

struct SpendableSpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SpendableSpike", provider: SpikeProvider()) { entry in
            SpendableWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Spendable")
        .description("Placeholder until milestone 8.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct SpendableWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpendableSpikeWidget()
    }
}
