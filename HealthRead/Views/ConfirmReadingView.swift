import SwiftUI

/// Confirmation screen — shows the photo next to editable fields so the user can check
/// every number before anything is written to Apple Health.
struct ConfirmReadingView: View {

    let deviceType: DeviceType
    let image: UIImage?
    let source: ReadingSource
    let onSave: () -> Void
    let onRetake: () -> Void
    let isSaving: Bool

    @Binding var measuredAt: Date

    // Blood pressure fields
    @Binding var systolic: String
    @Binding var diastolic: String
    @Binding var pulse: String

    // Weight fields
    @Binding var weight: String
    @Binding var weightUnit: WeightUnit

    @FocusState private var focusedField: Field?
    @State private var showFullPhoto = false

    enum Field {
        case systolic, diastolic, pulse, weight
    }

    var body: some View {
        VStack(spacing: 16) {
            if let image {
                photo(image)
            }

            sourceNote

            // Reading card
            VStack(spacing: 20) {
                HStack {
                    Text(deviceType.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    if focusedField != nil {
                        // The number pad has no return key; this is the way to close it.
                        Button("Done") { focusedField = nil }
                            .fontWeight(.semibold)
                            .buttonStyle(.bordered)
                    } else {
                        Image(systemName: deviceType.icon)
                            .font(.title2)
                            .foregroundStyle(deviceType == .bloodPressure ? .red : .blue)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 4)

                if deviceType == .bloodPressure {
                    bloodPressureFields
                } else {
                    weightFields
                }

                Divider()

                DatePicker("Measured", selection: $measuredAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .padding(.horizontal, 4)
            }
            .padding(20)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            if !issues.isEmpty {
                issueList
                    .padding(.horizontal, 20)
            }

            // Save button
            Button(action: {
                focusedField = nil // dismiss keyboard first
                onSave()
            }) {
                HStack {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    Text("Save to Health")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isSaveEnabled ? Color(.systemGreen) : Color(.systemGray3))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .disabled(!isSaveEnabled || isSaving)
            .padding(.horizontal, 20)
            .padding(.top, 4)

            Button(image == nil ? "Cancel" : "Retake") {
                focusedField = nil
                onRetake()
            }
            .buttonStyle(.bordered)
            .tint(.primary)

            Text("HealthRead isn\u{2019}t a medical device. Make sure the numbers match your monitor or scale before saving.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        // Keyboard is dismissed with the Done button in the card header or by scrolling.
        // (A tap gesture on this container would swallow taps meant for the text fields.)
        .fullScreenCover(isPresented: $showFullPhoto) {
            if let image {
                FullPhotoView(image: image)
            }
        }
    }

    // MARK: - Photo

    private func photo(_ image: UIImage) -> some View {
        Button {
            showFullPhoto = true
        } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(10)
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityLabel("Photo of the display")
        .accessibilityHint("Shows the photo full screen")
    }

    private var sourceNote: some View {
        Label {
            switch source {
            case .reader(let kind):
                Text("Read by \(kind.displayName). Check each number against the display.")
            case .manual:
                Text(image == nil ? "Type the numbers shown on your device." : "Type the numbers from the photo.")
            }
        } icon: {
            switch source {
            case .reader(let kind):
                Image(systemName: kind.runsOnDevice ? "iphone" : "cloud")
            case .manual:
                Image(systemName: "keyboard")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    // MARK: - Blood Pressure Fields

    private var bloodPressureFields: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                ReadingField(
                    label: "Systolic (top)",
                    value: $systolic,
                    suffix: nil,
                    keyboard: .numberPad,
                    focused: $focusedField,
                    field: .systolic
                )

                Text("/")
                    .font(.title)
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
                    .accessibilityHidden(true)

                ReadingField(
                    label: "Diastolic (bottom)",
                    value: $diastolic,
                    suffix: nil,
                    keyboard: .numberPad,
                    focused: $focusedField,
                    field: .diastolic
                )
            }

            Text("mmHg")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, -6)

            ReadingField(
                label: "Pulse (optional)",
                value: $pulse,
                suffix: "bpm",
                keyboard: .numberPad,
                focused: $focusedField,
                field: .pulse
            )
        }
    }

    // MARK: - Weight Fields

    private var weightFields: some View {
        VStack(spacing: 12) {
            ReadingField(
                label: "Weight",
                value: $weight,
                suffix: weightUnit.rawValue,
                keyboard: .decimalPad,
                focused: $focusedField,
                field: .weight
            )

            HStack {
                Text("Unit")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Unit", selection: $weightUnit) {
                    ForEach(WeightUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
        }
    }

    // MARK: - Checks

    private var issues: [ReadingIssue] {
        if deviceType == .bloodPressure {
            return ReadingChecks.bloodPressure(
                systolic: Int(systolic),
                diastolic: Int(diastolic),
                pulse: pulse.isEmpty ? nil : Int(pulse)
            )
        } else {
            return ReadingChecks.weight(Double(weight), unit: weightUnit)
        }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(issues) { issue in
                Label {
                    Text(issue.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.blocksSave ? .red : .orange)
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isSaveEnabled: Bool {
        let fieldsFilled: Bool
        if deviceType == .bloodPressure {
            let pulseOK = pulse.isEmpty || Int(pulse) != nil
            fieldsFilled = Int(systolic) != nil && Int(diastolic) != nil && pulseOK
        } else {
            fieldsFilled = Double(weight) != nil
        }
        return fieldsFilled && !issues.contains(where: \.blocksSave)
    }
}

// MARK: - Reading Field Component

private struct ReadingField: View {

    let label: String
    @Binding var value: String
    let suffix: String?
    let keyboard: UIKeyboardType
    var focused: FocusState<ConfirmReadingView.Field?>.Binding
    let field: ConfirmReadingView.Field

    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("--", text: $value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.center)
                    .focused(focused, equals: field)
                    .accessibilityLabel(label)

                if let suffix {
                    Text(suffix)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Full-Screen Photo

private struct FullPhotoView: View {

    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(max(zoom * value.magnification, 1), 5) }
                )
                .onTapGesture(count: 2) {
                    withAnimation { zoom = zoom > 1 ? 1 : 2.5 }
                }
                .accessibilityLabel("Photo of the display")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close")
        }
        .environment(\.colorScheme, .dark)
    }
}
