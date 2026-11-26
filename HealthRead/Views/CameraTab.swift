import HealthKit
import SwiftUI
import UIKit

/// Camera tab — scanning + processing + confirm + success flow, all in one view.
struct CameraTab: View {

    let camera: CameraController
    let healthKit: HealthKitManager
    @Binding var backCamera: Bool
    @Binding var selectedTab: Int

    // Readers (Claude, Apple models, text recognition), tried in order for the chosen mode
    @State private var coordinator = ReadingCoordinator()
    @AppStorage(ReadingMode.storageKey) private var readingModeRaw = ReadingMode.cloudAssisted.rawValue
    private var readingMode: ReadingMode { ReadingMode(rawValue: readingModeRaw) ?? .cloudAssisted }
    @AppStorage(ReadingMode.chosenKey) private var didChooseReadingMode = false
    @Environment(\.scenePhase) private var scenePhase

    // App state
    @State private var appState: AppState = .scanning
    /// The photo being read: a camera frame or a library photo. Kept on the confirm
    /// screen so the user can compare the numbers against it.
    @State private var capturedImage: UIImage?
    @State private var readingSource: ReadingSource = .manual
    @State private var measuredAt = Date()

    // Blood pressure fields
    @State private var systolic = ""
    @State private var diastolic = ""
    @State private var pulse = ""

    // Weight fields
    @State private var weight = ""
    @State private var weightUnit: WeightUnit = .lbs

    // UI state
    @State private var saveSummary = ""
    @State private var savedToAppleHealth = true
    @State private var isSaving = false
    @State private var readErrorMessage: String?
    @State private var showReadError = false
    @State private var saveErrorMessage: String?
    @State private var showSaveError = false
    /// Bumped on every new capture so a late result from a cancelled analysis is ignored.
    @State private var analysisID = UUID()
    @State private var showSettings = false
    /// The numbers as the reader returned them, to tell whether the user corrected them.
    @State private var readerValues: String?
    /// "camera" or "photo", for analytics.
    @State private var inputSource = "camera"
    @State private var manualAfterFailedRead = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState {
            case .scanning:
                scanningLayer
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .padding(.trailing, 12)
                        .accessibilityLabel("Settings")
                    }
                    .environment(\.colorScheme, .dark)
                    .transition(.opacity)

            case .processing:
                processingLayer
                    .environment(\.colorScheme, .dark)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

            case .confirm(let device):
                confirmLayer(device: device)
                    .transition(.move(edge: .bottom))

            case .saved(let device):
                SuccessView(
                    deviceType: device,
                    summary: saveSummary,
                    measuredAt: measuredAt,
                    savedToAppleHealth: savedToAppleHealth,
                    onDone: { tab in
                        resetToScanning()
                        selectedTab = tab
                    }
                )
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appState)
        .alert("Couldn\u{2019}t Read the Display", isPresented: $showReadError) {
            Button("Enter Blood Pressure") { startManualEntry(.bloodPressure, keepingImage: true) }
            Button("Enter Weight") { startManualEntry(.weightScale, keepingImage: true) }
            Button("Try Again", role: .cancel) { resetToScanning() }
        } message: {
            Text(readErrorMessage ?? "Please try again.")
        }
        .alert("Couldn\u{2019}t Save", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Something went wrong. Your reading was not saved.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            weightUnit = Self.preferredWeightUnit
        }
        // In Cloud Assisted mode, do App Attest setup and wake the server while the person
        // lines up the shot, so it isn't added to the first reading. Again on each return
        // to the app, since the server goes cold after a few idle minutes.
        .task(id: "\(readingModeRaw)|\(didChooseReadingMode)|\(scenePhase == .active)") {
            guard didChooseReadingMode, readingMode == .cloudAssisted, scenePhase == .active else { return }
            await ClaudeReader.prepare()
        }
    }

    // MARK: - Scanning

    private var scanningLayer: some View {
        ScanningView(
            camera: camera,
            backCamera: $backCamera,
            onFrameCaptured: { frame, hint in
                triggerHaptic(.medium)
                guard let image = UIImage.from(pixelBuffer: frame) else { return }
                beginAnalysis(of: image, hint: hint, source: "camera")
            },
            onPhotoPicked: { image in
                beginAnalysis(of: image.normalizedForReading(), hint: nil, source: "photo")
            },
            onEnterManually: { device in
                startManualEntry(device, keepingImage: false)
            }
        )
    }

    // MARK: - Processing (analyzing the photo)

    private var processingLayer: some View {
        VStack {
            Spacer()

            if let capturedImage {
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                            .foregroundStyle(.white.opacity(0.5))
                    )
                    .padding(.horizontal, 20)
                    .accessibilityLabel("Captured photo")
            }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the display\u{2026}")
                        .fontWeight(.semibold)
                }
                .font(.title3)

                Text(readingMode == .onDevice
                     ? "Reading on this iPhone. You\u{2019}ll check the numbers before anything is saved."
                     : "You\u{2019}ll check the numbers before anything is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)

            Button(action: resetToScanning) {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(.vertical, 16)

            Spacer()
        }
    }

    // MARK: - Confirm

    private func confirmLayer(device: DeviceType) -> some View {
        NavigationStack {
            ScrollView {
                ConfirmReadingView(
                    deviceType: device,
                    image: capturedImage,
                    source: readingSource,
                    onSave: { saveReading(device: device) },
                    onRetake: resetToScanning,
                    isSaving: isSaving,
                    measuredAt: $measuredAt,
                    systolic: $systolic,
                    diastolic: $diastolic,
                    pulse: $pulse,
                    weight: $weight,
                    weightUnit: $weightUnit
                )
                .padding(.top, 20)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color(.systemGroupedBackground))
        }
    }

    // MARK: - Analysis

    private func beginAnalysis(of image: UIImage, hint: DeviceType?, source: String) {
        inputSource = source
        capturedImage = image
        measuredAt = Date()
        let id = UUID()
        analysisID = id
        withAnimation { appState = .processing }
        Task { await performAnalysis(image: image, hint: hint, id: id) }
    }

    private func performAnalysis(image: UIImage, hint: DeviceType?, id: UUID) async {
        guard let cgImage = image.cgImage else {
            await MainActor.run {
                readErrorMessage = "Couldn\u{2019}t prepare the photo."
                showReadError = true
            }
            return
        }
        let started = Date()
        let outcome = await coordinator.read(cgImage, mode: readingMode, hint: hint)
        let (result, reader) = (outcome.result, outcome.reader)

        let resultLabel: String
        switch result {
        case .bloodPressure, .weight: resultLabel = "read"
        case .noDeviceDetected: resultLabel = "no_device"
        case .error: resultLabel = "failed"
        }
        Analytics.capture("reading_attempt", [
            "mode": readingMode.rawValue,
            "input": inputSource,
            "outcome": resultLabel,
            "reader": reader?.rawValue ?? "none",
            "attempts": outcome.attempts.map(\.analyticsValue),
            "total_ms": Int(Date().timeIntervalSince(started) * 1000),
            "mobileclip_hint": hint.map { $0 == .bloodPressure ? "blood_pressure" : "weight_scale" } ?? "none",
            "apple_intelligence": ReadingCoordinator.availability(of: .appleOnDevice) == nil,
        ])

        await MainActor.run {
            // Ignore results for an analysis the user cancelled or replaced.
            guard id == analysisID, appState == .processing else {
                Analytics.capture("reading_discarded", ["stage": "processing", "input": inputSource])
                return
            }

            switch result {
            case .bloodPressure(let reading):
                systolic = String(reading.systolic)
                diastolic = String(reading.diastolic)
                pulse = reading.pulse.map { String($0) } ?? ""
                readingSource = reader.map(ReadingSource.reader) ?? .manual
                readerValues = currentValues(.bloodPressure)
                withAnimation { appState = .confirm(.bloodPressure) }

            case .weight(let reading):
                weight = String(format: "%.1f", reading.weight)
                weightUnit = reading.unit
                readingSource = reader.map(ReadingSource.reader) ?? .manual
                readerValues = currentValues(.weightScale)
                withAnimation { appState = .confirm(.weightScale) }

            case .noDeviceDetected:
                readErrorMessage = "No blood pressure monitor or scale display was found in the photo. Try again with the display filling more of the frame, or type the numbers in."
                showReadError = true

            case .error(let message, _):
                readErrorMessage = message
                showReadError = true
            }
        }
    }

    // MARK: - Manual Entry

    private func startManualEntry(_ device: DeviceType, keepingImage: Bool) {
        manualAfterFailedRead = keepingImage
        readerValues = nil
        Analytics.capture("manual_entry_started", [
            "device_type": device == .bloodPressure ? "blood_pressure" : "weight_scale",
            "after_failed_read": keepingImage,
        ])
        if !keepingImage {
            capturedImage = nil
            measuredAt = Date()
        }
        systolic = ""
        diastolic = ""
        pulse = ""
        weight = ""
        weightUnit = Self.preferredWeightUnit
        readingSource = .manual
        withAnimation { appState = .confirm(device) }
    }

    // MARK: - Save

    private func saveReading(device: DeviceType) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            do {
                if device == .bloodPressure {
                    guard let sys = Int(systolic), let dia = Int(diastolic) else { isSaving = false; return }
                    let reading = BloodPressureReading(systolic: sys, diastolic: dia, pulse: Int(pulse), timestamp: measuredAt)
                    savedToAppleHealth = try await healthKit.saveBloodPressure(reading) == .appleHealth
                    saveSummary = "\(sys)/\(dia) mmHg" + (reading.pulse.map { " · \($0) bpm" } ?? "")
                } else {
                    guard let wt = Double(weight) else { isSaving = false; return }
                    let reading = WeightReading(weight: wt, unit: weightUnit, timestamp: measuredAt)
                    savedToAppleHealth = try await healthKit.saveWeight(reading) == .appleHealth
                    saveSummary = String(format: "%.1f %@", wt, weightUnit.rawValue)
                    UserDefaults.standard.set(weightUnit.rawValue, forKey: "weightUnit")
                }

                triggerHaptic(.success)
                let source: String
                switch readingSource {
                case .reader(let kind): source = kind.rawValue
                case .manual: source = manualAfterFailedRead ? "manual_after_failed_read" : "manual"
                }
                // `edited` compares the saved numbers with the reader's; the numbers themselves are never sent.
                Analytics.capture("reading_saved", [
                    "device_type": device == .bloodPressure ? "blood_pressure" : "weight_scale",
                    "source": source,
                    "edited": readerValues.map { $0 != currentValues(device) } ?? false,
                    "time_changed": abs(measuredAt.timeIntervalSinceNow) > 120,
                    "destination": savedToAppleHealth ? "apple_health" : "app_only",
                    "mode": readingMode.rawValue,
                ])
                await MainActor.run {
                    isSaving = false
                    withAnimation { appState = .saved(device) }
                }
            } catch {
                let denied = (error as? HKError)?.code == .errorAuthorizationDenied
                Analytics.capture("reading_save_failed", ["reason": denied ? "health_access_denied" : "other"])
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = Self.describeSaveError(error)
                    showSaveError = true
                }
            }
        }
    }

    private static func describeSaveError(_ error: Error) -> String {
        if let hkError = error as? HKError, hkError.code == .errorAuthorizationDenied {
            return "HealthRead isn\u{2019}t allowed to write to Apple Health. Turn it on in Settings \u{203A} Health \u{203A} Data Access & Devices \u{203A} HealthRead, then tap Save again."
        }
        return "Your reading was not saved. \(error.localizedDescription)"
    }

    // MARK: - Reset

    /// The values on the confirm screen as one string, used only to detect edits on this phone.
    private func currentValues(_ device: DeviceType) -> String {
        device == .bloodPressure ? "\(systolic)/\(diastolic)/\(pulse)" : "\(weight)\(weightUnit.rawValue)"
    }

    private func resetToScanning() {
        if case .confirm = appState {
            Analytics.capture("reading_discarded", ["stage": "confirm", "input": capturedImage == nil ? "manual" : inputSource])
        }
        readerValues = nil
        manualAfterFailedRead = false
        analysisID = UUID()
        capturedImage = nil
        systolic = ""
        diastolic = ""
        pulse = ""
        weight = ""
        isSaving = false
        withAnimation { appState = .scanning }
    }

    // MARK: - Helpers

    /// The last unit the user saved with, else the region's usual unit.
    private static var preferredWeightUnit: WeightUnit {
        if let saved = UserDefaults.standard.string(forKey: "weightUnit"),
           let unit = WeightUnit(rawValue: saved) {
            return unit
        }
        return Locale.current.measurementSystem == .us ? .lbs : .kg
    }

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
