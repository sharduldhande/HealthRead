import SwiftUI

/// Apple Health-style weight history tab.
struct WeightHistoryTab: View {

    let healthKit: HealthKitManager
    @State private var readings: [WeightReading] = []
    @State private var isLoading = true
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if readings.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Latest reading highlight card
                        if let latest = readings.first {
                            Section {
                                latestCard(latest)
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        // History grouped by day
                        ForEach(groupedByDay, id: \.key) { day, dayReadings in
                            Section(header: Text(day)) {
                                ForEach(dayReadings) { reading in
                                    readingRow(reading)
                                }
                                .onDelete { offsets in
                                    if let index = offsets.first {
                                        let reading = dayReadings[index]
                                        Task {
                                            try? await healthKit.deleteWeight(reading)
                                            await loadReadings()
                                            editMode = .inactive
                                        }
                                    }
                                }
                                .deleteDisabled(editMode == .inactive)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Weight")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !readings.isEmpty {
                        EditButton()
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .refreshable {
                await loadReadings()
            }
        }
        .onAppear {
            Task { await loadReadings() }
        }
    }

    // MARK: - Latest Card

    private func latestCard(_ reading: WeightReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "scalemass.fill")
                    .foregroundStyle(.blue)
                Text("Latest")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(reading.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", reading.weight))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text(reading.unit.rawValue)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }

    // MARK: - Row

    private func readingRow(_ reading: WeightReading) -> some View {
        HStack {
            Image(systemName: "scalemass.fill")
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f %@", reading.weight, reading.unit.rawValue))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(reading.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "scalemass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Weight Readings")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Use the Camera tab to scan\nyour weight scale.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Data

    private func loadReadings() async {
        readings = await healthKit.fetchRecentWeight()
        isLoading = false
    }

    private var groupedByDay: [(key: String, value: [WeightReading])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: readings) { reading -> String in
            if calendar.isDateInToday(reading.timestamp) { return "Today" }
            else if calendar.isDateInYesterday(reading.timestamp) { return "Yesterday" }
            else { return reading.timestamp.formatted(date: .abbreviated, time: .omitted) }
        }
        return grouped.sorted { a, b in
            if a.key == "Today" { return true }
            if b.key == "Today" { return false }
            if a.key == "Yesterday" { return true }
            if b.key == "Yesterday" { return false }
            return a.key > b.key
        }
    }
}
