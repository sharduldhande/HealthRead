import SwiftUI

/// Confirmation screen — shows OCR results in editable fields, lets user save to HealthKit.
struct ConfirmReadingView: View {

    let deviceType: DeviceType
    let frozenFrame: CVPixelBuffer?
    let onSave: () -> Void
    let onRetake: () -> Void

    // Blood pressure fields
    @Binding var systolic: String
    @Binding var diastolic: String
    @Binding var pulse: String

    // Weight fields
    @Binding var weight: String
    @Binding var weightUnit: WeightUnit

    @FocusState private var focusedField: Field?

    enum Field {
        case systolic, diastolic, pulse, weight
    }

    var body: some View {
        VStack(spacing: 16) {
            // Frozen frame thumbnail
            if let frozenFrame {
                _FrozenFrameView(frame: frozenFrame)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
            }

            // Reading card
            VStack(spacing: 20) {
                // Header
                HStack {
                    Text(deviceType.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: deviceType.icon)
                        .font(.title2)
                        .foregroundStyle(deviceType == .bloodPressure ? .red : .blue)
                }
                .padding(.horizontal, 4)

                if deviceType == .bloodPressure {
                    bloodPressureFields
                } else {
                    weightFields
                }
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            Spacer()

            // Save button
            Button(action: {
                focusedField = nil // dismiss keyboard first
                onSave()
            }) {
                HStack {
                    Image(systemName: "checkmark")
                        .fontWeight(.bold)
                    Text("Save to Health")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isSaveEnabled ? Color(.systemGreen) : Color(.systemGray3))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .disabled(!isSaveEnabled)
            .padding(.horizontal, 20)

            // Retake button
            Button(action: {
                focusedField = nil
                onRetake()
            }) {
                Text("Retake")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
        // Tap outside fields to dismiss keyboard
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
        // Toolbar with Done button for keyboard
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Blood Pressure Fields

    private var bloodPressureFields: some View {
        VStack(spacing: 12) {
            ReadingField(
                label: "Systolic",
                value: $systolic,
                suffix: "mmHg",
                focused: $focusedField,
                field: .systolic
            )

            HStack {
                Spacer()
                Text("/")
                    .font(.system(size: 32, weight: .light, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ReadingField(
                label: "Diastolic",
                value: $diastolic,
                suffix: "mmHg",
                focused: $focusedField,
                field: .diastolic
            )

            ReadingField(
                label: "Pulse (optional)",
                value: $pulse,
                suffix: "bpm",
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
                focused: $focusedField,
                field: .weight
            )

            // Unit picker
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

    // MARK: - Validation

    private var isSaveEnabled: Bool {
        if deviceType == .bloodPressure {
            return Int(systolic) != nil && Int(diastolic) != nil
        } else {
            return Double(weight) != nil
        }
    }
}

// MARK: - Reading Field Component

private struct ReadingField: View {

    let label: String
    @Binding var value: String
    let suffix: String
    var focused: FocusState<ConfirmReadingView.Field?>.Binding
    let field: ConfirmReadingView.Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("--", text: $value)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused(focused, equals: field)

                Text(suffix)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Frozen Frame Display

private struct _FrozenFrameView: UIViewRepresentable {

    let frame: CVPixelBuffer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.layer.contentsGravity = .resizeAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layer.contents = frame
    }
}
