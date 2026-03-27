import CoreML
import SwiftUI
import UIKit

/// Camera tab — scanning + processing + confirm + success flow, all in one view.
struct CameraTab: View {

    let camera: CameraController
    let healthKit: HealthKitManager
    @Binding var backCamera: Bool
    @Binding var selectedTab: Int

    // Gemini service
    @State private var geminiService = GeminiService()

    // App state
    @State private var appState: AppState = .scanning
    @State private var frozenFrame: CVPixelBuffer?

    // Blood pressure fields
    @State private var systolic = ""
    @State private var diastolic = ""
    @State private var pulse = ""

    // Weight fields
    @State private var weight = ""
    @State private var weightUnit: WeightUnit = .lbs

    // UI state
    @State private var saveSummary = ""
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState {
            case .scanning:
                scanningLayer
                    .transition(.opacity)

            case .processing:
                processingLayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))

            case .confirm(let device):
                confirmLayer(device: device)
                    .transition(.move(edge: .bottom))

            case .saved(let device):
                SuccessView(
                    deviceType: device,
                    summary: saveSummary,
                    onDone: { tab in
                        resetToScanning()
                        selectedTab = tab
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState)
        .alert("Unable to Read", isPresented: $showError) {
            Button("Try Again", role: .cancel) {
                resetToScanning()
            }
        } message: {
            Text(errorMessage ?? "Please try again")
        }
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "weightUnit"),
               let unit = WeightUnit(rawValue: saved) {
                weightUnit = unit
            }
        }
    }

    // MARK: - Scanning

    private var scanningLayer: some View {
        ScanningView(
            camera: camera,
            backCamera: $backCamera,
            onFrameCaptured: { frame in
                triggerHaptic(.medium)
                frozenFrame = frame
                withAnimation {
                    appState = .processing
                }
                Task {
                    await performGeminiAnalysis(frame: frame)
                }
            }
        )
    }

    // MARK: - Processing (Gemini analyzing)

    private var processingLayer: some View {
        VStack {
            Spacer()

            if let frozenFrame {
                FrozenFrameThumb(frame: frozenFrame)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundStyle(.white.opacity(0.5))
                    )
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing image...")
                        .fontWeight(.semibold)
                }
                .font(.title3)

                Text("Reading device display with AI")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            Button(action: resetToScanning) {
                HStack {
                    Image(systemName: "xmark")
                    Text("Cancel")
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)

            Spacer()
        }
    }

    // MARK: - Confirm

    private func confirmLayer(device: DeviceType) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 20)
                    ConfirmReadingView(
                        deviceType: device,
                        frozenFrame: frozenFrame,
                        onSave: { saveReading(device: device) },
                        onRetake: resetToScanning,
                        systolic: $systolic,
                        diastolic: $diastolic,
                        pulse: $pulse,
                        weight: $weight,
                        weightUnit: $weightUnit
                    )
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Gemini Analysis

    private func performGeminiAnalysis(frame: CVPixelBuffer) async {
        isProcessing = true

        let result = await geminiService.analyze(frame: frame)

        await MainActor.run {
            isProcessing = false

            switch result {
            case .bloodPressure(let reading):
                systolic = String(reading.systolic)
                diastolic = String(reading.diastolic)
                pulse = reading.pulse.map { String($0) } ?? ""
                withAnimation { appState = .confirm(.bloodPressure) }

            case .weight(let reading):
                weight = String(format: "%.1f", reading.weight)
                weightUnit = reading.unit
                withAnimation { appState = .confirm(.weightScale) }

            case .noDeviceDetected:
                errorMessage = "No blood pressure monitor or weight scale detected. Make sure the device display is clearly visible and try again."
                showError = true

            case .error(let message):
                errorMessage = message
                showError = true
            }
        }
    }

    // MARK: - Save

    private func saveReading(device: DeviceType) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            do {
                if device == .bloodPressure {
                    guard let sys = Int(systolic), let dia = Int(diastolic) else { isSaving = false; return }
                    let reading = BloodPressureReading(systolic: sys, diastolic: dia, pulse: Int(pulse))
                    try await healthKit.saveBloodPressure(reading)
                    saveSummary = "\(sys)/\(dia) mmHg" + (reading.pulse.map { " · \($0) bpm" } ?? "")
                } else {
                    guard let wt = Double(weight) else { isSaving = false; return }
                    let reading = WeightReading(weight: wt, unit: weightUnit)
                    try await healthKit.saveWeight(reading)
                    saveSummary = String(format: "%.1f %@", wt, weightUnit.rawValue)
                    UserDefaults.standard.set(weightUnit.rawValue, forKey: "weightUnit")
                }

                triggerHaptic(.success)
                await MainActor.run {
                    isSaving = false
                    withAnimation { appState = .saved(device) }
                }
            } catch {
                print("Failed to save: \(error)")
                isSaving = false
            }
        }
    }

    // MARK: - Reset

    private func resetToScanning() {
        frozenFrame = nil
        systolic = ""
        diastolic = ""
        pulse = ""
        weight = ""
        isProcessing = false
        isSaving = false
        withAnimation { appState = .scanning }
    }

    // MARK: - Haptics

    private func triggerHaptic(_ style: HapticStyle) {
        switch style {
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private enum HapticStyle { case medium, success }
}

// MARK: - Reusable Frozen Frame View

struct FrozenFrameThumb: UIViewRepresentable {
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
