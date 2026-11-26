import SwiftUI

/// Reading-mode choice plus which readers work on this iPhone.
struct SettingsView: View {

    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.cloudAssisted.rawValue
    @AppStorage(Analytics.enabledKey) private var analyticsEnabled = true
    /// "" means ask when a scale's display shows no unit.
    @AppStorage(WeightUnit.defaultKey) private var defaultWeightUnit = ""
    @Environment(\.dismiss) private var dismiss

    private var readingMode: ReadingMode { ReadingMode(rawValue: readingModeRaw) ?? .cloudAssisted }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ReadingMode.allCases) { mode in
                        ReadingModeCard(mode: mode, isSelected: readingMode == mode) {
                            if readingMode != mode {
                                Analytics.capture("reading_mode_changed", ["mode": mode.rawValue])
                            }
                            readingModeRaw = mode.rawValue
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Reading method")
                }

                Section {
                    ForEach(readingMode.readers) { kind in
                        let reason = ReadingCoordinator.availability(of: kind)
                        HStack {
                            Image(systemName: kind.runsOnDevice ? "iphone" : "cloud")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.displayName)
                                Text(reason ?? "Available")
                                    .font(.caption)
                                    .foregroundStyle(reason == nil ? Color.green : Color.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Tried in this order")
                } footer: {
                    Text("If a reader can\u{2019}t run, HealthRead moves on to the next one. You always check the numbers before saving.")
                }

                Section {
                    Picker("Default weight unit", selection: $defaultWeightUnit) {
                        Text("Ask me").tag("")
                        ForEach(WeightUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit.rawValue)
                        }
                    }
                } header: {
                    Text("Weight")
                } footer: {
                    Text("Used when a scale\u{2019}s display doesn\u{2019}t show kg or lbs. With \u{201C}Ask me\u{201D}, you choose on the confirm screen.")
                }

                Section {
                    Toggle("Share anonymous usage data", isOn: $analyticsEnabled)
                        .onChange(of: analyticsEnabled) { _, enabled in
                            // Record the opt-out itself once, then stop sending.
                            if !enabled { Analytics.capture("analytics_disabled", force: true) }
                        }
                } footer: {
                    Text("Which features are used and how often reading works, with a random install ID. Never photos, readings or Health data.")
                }

                Section {
                    Text("Readings are saved to Apple Health on your iPhone. In Cloud Assisted mode, a photo may be read by Apple\u{2019}s Private Cloud Compute (Apple says it keeps no data) and, if needed, sent over HTTPS to HealthRead\u{2019}s reader, which asks Gemini (Google) to read it, or Claude (Anthropic) when Gemini is busy, and keeps no copy. The confirm screen always says which one read it. Fully On-Device mode sends nothing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
