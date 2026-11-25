import SwiftUI

/// First-run screen: explains what HealthRead does and lets the user choose how photos are read.
/// Shown before the camera and Apple Health permission prompts.
struct OnboardingView: View {

    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.cloudAssisted.rawValue
    @AppStorage(ReadingMode.chosenKey) private var didChooseReadingMode = false
    @State private var selection: ReadingMode = .cloudAssisted
    @AppStorage(Analytics.enabledKey) private var analyticsEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text("HealthRead")
                        .font(.largeTitle.bold())
                    Text("Take a photo of your blood pressure monitor or scale. HealthRead reads the numbers, you check them, and they\u{2019}re saved to Apple Health.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                Text("How should photos be read?")
                    .font(.title3.bold())

                ForEach(ReadingMode.allCases) { mode in
                    ReadingModeCard(mode: mode, isSelected: selection == mode) {
                        selection = mode
                    }
                }

                Text("You can change this anytime in Settings. Either way, nothing is saved until you confirm the numbers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $analyticsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Share anonymous usage data")
                            .font(.subheadline.weight(.semibold))
                        Text("Which features are used and how often reading works. Never your photos, readings or Health data. You can turn this off in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))

                Button {
                    readingModeRaw = selection.rawValue
                    didChooseReadingMode = true
                    Analytics.capture("onboarding_completed", [
                        "mode": selection.rawValue,
                        "apple_intelligence": ReadingCoordinator.availability(of: .appleOnDevice) == nil,
                    ])
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .onAppear {
            selection = ReadingMode(rawValue: readingModeRaw) ?? .cloudAssisted
        }
    }
}

/// A selectable card describing one reading mode, used in onboarding and Settings.
struct ReadingModeCard: View {

    let mode: ReadingMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: mode == .onDevice ? "iphone" : "cloud")
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.title)
                        .font(.headline)
                    Text(Self.summary(for: mode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static func summary(for mode: ReadingMode) -> String {
        let onDeviceReader = ReadingCoordinator.availability(of: .appleOnDevice) == nil
            ? "Apple Intelligence"
            : "Apple\u{2019}s text recognition (less accurate on segment displays)"
        switch mode {
        case .onDevice:
            return "Photos never leave your iPhone. On this iPhone, readings use \(onDeviceReader)."
        case .cloudAssisted:
            return "Uses Apple Intelligence first (Apple\u{2019}s Private Cloud Compute, then your iPhone) where supported. Otherwise, or if Apple\u{2019}s models can\u{2019}t read it, one photo goes to HealthRead\u{2019}s reader (Claude by Anthropic). Photos aren\u{2019}t stored."
        }
    }
}

#Preview {
    OnboardingView()
}
