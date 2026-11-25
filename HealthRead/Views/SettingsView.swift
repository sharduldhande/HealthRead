import SwiftUI

/// Reading-mode choice plus which readers work on this iPhone.
struct SettingsView: View {

    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.cloudAssisted.rawValue
    @Environment(\.dismiss) private var dismiss

    private var readingMode: ReadingMode { ReadingMode(rawValue: readingModeRaw) ?? .cloudAssisted }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ReadingMode.allCases) { mode in
                        ReadingModeCard(mode: mode, isSelected: readingMode == mode) {
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
                    Text("Readings are saved to Apple Health on your iPhone. In Cloud Assisted mode, one photo per reading is sent over HTTPS to HealthRead\u{2019}s reader, which asks Claude (Anthropic) to read it and keeps no copy. Fully On-Device mode sends nothing.")
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
