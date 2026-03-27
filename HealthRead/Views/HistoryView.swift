import SwiftUI

/// Sheet displaying recent health readings from HealthKit, grouped by day.
struct HistoryView: View {

    let healthKit: HealthKitManager

    @State private var bpReadings: [BloodPressureReading] = []
    @State private var weightReadings: [WeightReading] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if allReadings.isEmpty {
                    emptyState
                } else {
                    readingsList
                }
            }
            .navigationTitle("Recent Readings")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            async let bp = healthKit.fetchRecentBloodPressure()
            async let wt = healthKit.fetchRecentWeight()
            bpReadings = await bp
            weightReadings = await wt
            isLoading = false
        }
    }

    // MARK: - Readings List

    private var readingsList: some View {
        List {
            ForEach(groupedByDay, id: \.key) { day, readings in
                Section(header: Text(day)) {
                    ForEach(readings, id: \.id) { entry in
                        readingRow(entry)
                    }
                }
            }

            Section {
                Button(action: openHealthApp) {
                    HStack {
                        Text("Open Health App")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
            } footer: {
                Text("Powered by Apple Health")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Readings Yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Point your camera at a blood pressure\nmonitor or weight scale to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Row View

    @ViewBuilder
    private func readingRow(_ entry: HistoryEntry) -> some View {
        HStack {
            Image(systemName: entry.icon)
                .foregroundStyle(entry.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayValue)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Data Grouping

    private var allReadings: [HistoryEntry] {
        var entries: [HistoryEntry] = []

        for bp in bpReadings {
            entries.append(HistoryEntry(
                icon: "heart.fill",
                color: .red,
                displayValue: "\(bp.systolic)/\(bp.diastolic) mmHg" + (bp.pulse.map { " \u{00B7} \($0) bpm" } ?? ""),
                timestamp: bp.timestamp
            ))
        }

        for wt in weightReadings {
            entries.append(HistoryEntry(
                icon: "scalemass.fill",
                color: .blue,
                displayValue: String(format: "%.1f %@", wt.weight, wt.unit.rawValue),
                timestamp: wt.timestamp
            ))
        }

        return entries.sorted { $0.timestamp > $1.timestamp }
    }

    private var groupedByDay: [(key: String, value: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: allReadings) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                return entry.timestamp.formatted(date: .abbreviated, time: .omitted)
            }
        }
        // Sort: Today first, then Yesterday, then by date descending
        return grouped.sorted { a, b in
            if a.key == "Today" { return true }
            if b.key == "Today" { return false }
            if a.key == "Yesterday" { return true }
            if b.key == "Yesterday" { return false }
            return a.key > b.key
        }
    }

    private func openHealthApp() {
        if let url = URL(string: "x-apple-health://") {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - History Entry Model

private struct HistoryEntry: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let displayValue: String
    let timestamp: Date
}
