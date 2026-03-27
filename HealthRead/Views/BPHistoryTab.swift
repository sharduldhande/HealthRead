import SwiftUI

/// Apple Health-style blood pressure history tab.
struct BPHistoryTab: View {

    let healthKit: HealthKitManager
    @State private var readings: [BloodPressureReading] = []
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
                                            try? await healthKit.deleteBloodPressure(reading)
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
            .navigationTitle("Blood Pressure")
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

    private func latestCard(_ reading: BloodPressureReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                Text("Latest")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(reading.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(reading.systolic)/\(reading.diastolic)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("mmHg")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if let pulse = reading.pulse {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.pink)
                    Text("\(pulse)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text("bpm")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // BP category indicator
            bpCategory(systolic: reading.systolic, diastolic: reading.diastolic)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 4)
    }

    // MARK: - BP Category

    @ViewBuilder
    private func bpCategory(systolic: Int, diastolic: Int) -> some View {
        let (label, color) = classifyBP(systolic: systolic, diastolic: diastolic)
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func classifyBP(systolic: Int, diastolic: Int) -> (String, Color) {
        if systolic < 120 && diastolic < 80 {
            return ("Normal", .green)
        } else if systolic < 130 && diastolic < 80 {
            return ("Elevated", .yellow)
        } else if systolic < 140 || diastolic < 90 {
            return ("High Blood Pressure Stage 1", .orange)
        } else {
            return ("High Blood Pressure Stage 2", .red)
        }
    }

    // MARK: - Row

    private func readingRow(_ reading: BloodPressureReading) -> some View {
        HStack {
            Image(systemName: "heart.fill")
                .foregroundStyle(.red)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(reading.systolic)/\(reading.diastolic)")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                    Text("mmHg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let pulse = reading.pulse {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(pulse) bpm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(reading.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let (_, color) = classifyBP(systolic: reading.systolic, diastolic: reading.diastolic)
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Blood Pressure Readings")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Use the Camera tab to scan\nyour blood pressure monitor.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Data

    private func loadReadings() async {
        readings = await healthKit.fetchRecentBloodPressure()
        isLoading = false
    }

    private var groupedByDay: [(key: String, value: [BloodPressureReading])] {
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
