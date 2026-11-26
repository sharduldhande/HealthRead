import AVFoundation
import CoreML
import PhotosUI
import SwiftUI

/// Minimum cosine similarity to consider a device "detected"
private let detectionConfidenceThreshold: Float = 0.22

/// The prompts used for zero-shot classification of health devices
private let healthDevicePrompt = Prompt(
    prefix: "A photo of a",
    suffix: "",
    classNames: [
        DeviceType.bloodPressure.rawValue,
        DeviceType.weightScale.rawValue,
    ]
)

// MARK: - Scanning View

/// Full-screen camera scanning view with MobileCLIP detection indicator + capture button.
/// MobileCLIP runs continuously to show a visual hint when a device is in view.
/// User taps the shutter button to capture and send to Gemini for analysis.
struct ScanningView: View {

    let camera: CameraController
    @Binding var backCamera: Bool
    /// The captured frame, the device MobileCLIP thinks is in view (a hint for text
    /// recognition), and the frame's glare score (for analytics).
    let onFrameCaptured: (CVPixelBuffer, DeviceType?, Double) -> Void
    let onPhotoPicked: (UIImage) -> Void
    let onEnterManually: (DeviceType) -> Void

    // MobileCLIP state (for detection indicator only)
    @State private var zsclassifier = ZSImageClassification(model: defaultModel.factory())
    @State private var textEmbeddings: [MLMultiArray] = []
    @State private var framesToDisplay: AsyncStream<CVImageBuffer>?
    @State private var detectedDevice: DeviceType?
    @State private var isModelLoaded = false
    @State private var pulseAnimation = false
    @State private var latestFrame: CVPixelBuffer?
    @State private var pickedPhoto: PhotosPickerItem?
    /// Zoom when the current pinch began.
    @State private var pinchStartZoom: CGFloat?
    /// The last half second of glare-scored frames; the shutter uses the cleanest.
    @State private var recentFrames = RecentFrames()
    /// Shown after a few glary frames in a row, cleared after a few clean ones.
    @State private var showGlareHint = false
    @State private var glareStreak = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 60)

                // Camera viewport
                ZStack {
                    if camera.status == .denied || camera.status == .unavailable {
                        cameraUnavailableView
                    } else if let framesToDisplay {
                        VideoFrameView(frames: framesToDisplay, backCamera: $backCamera)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .contentShape(Rectangle())
                            .gesture(pinchToZoom)
                            .overlay(alignment: .bottomLeading) { zoomButton }
                    } else {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(Color(.systemGray6))
                            .overlay {
                                ProgressView()
                                    .controlSize(.large)
                            }
                    }

                    // Detection border animation
                    if detectedDevice != nil {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.green, lineWidth: 3)
                            .scaleEffect(pulseAnimation ? 1.02 : 1.0)
                            .opacity(pulseAnimation ? 0.8 : 1.0)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .task {
                    guard !Task.isCancelled else { return }
                    await loadModelAndStart()
                }

                Spacer().frame(height: 16)

                // Status pill
                statusPill
                    .padding(.horizontal, 20)

                Spacer().frame(height: 16)

                // Photo library · capture · manual entry
                HStack {
                    photoButton
                        .frame(maxWidth: .infinity)
                    captureButton
                    manualEntryButton
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run { onPhotoPicked(image) }
                }
            }
        }
        .onChange(of: detectedDevice) { _, newDevice in
            if newDevice != nil {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            } else {
                pulseAnimation = false
            }
        }
    }

    // MARK: - Zoom

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoomFactor
                pinchStartZoom = start
                camera.setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    /// Steps through 1×, 2× and 3× like the Camera app; pinch for anything in between.
    private var zoomButton: some View {
        let zoom = camera.zoomFactor
        let next = [2, 3].map(CGFloat.init).first { $0 > zoom + 0.05 } ?? 1
        let label = abs(zoom - zoom.rounded()) < 0.05
            ? String(format: "%.0f\u{00D7}", zoom)
            : String(format: "%.1f\u{00D7}", zoom)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            camera.setZoom(next)
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(zoom > 1.05 ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .padding(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zoom")
        .accessibilityValue(label)
        .accessibilityHint("Pinch the camera view to zoom in or out")
        .accessibilityAdjustableAction { direction in
            camera.setZoom(direction == .increment ? zoom + 0.5 : zoom - 0.5)
        }
    }

    // MARK: - Capture Button

    private var captureButton: some View {
        Button {
            guard let latestFrame else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            // The least glary frame from the last half second, else the newest one.
            if let best = recentFrames.best() {
                onFrameCaptured(best.frame, detectedDevice, best.glare)
            } else {
                onFrameCaptured(latestFrame, detectedDevice, FrameQuality.glareFraction(latestFrame))
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 72, height: 72)
                Circle()
                    .stroke(.white.opacity(0.3), lineWidth: 4)
                    .frame(width: 82, height: 82)
            }
        }
        .disabled(latestFrame == nil)
        .opacity(latestFrame != nil ? 1.0 : 0.4)
        .accessibilityLabel("Capture")
        .accessibilityHint("Takes a photo of the display and reads it")
    }

    // MARK: - Camera Unavailable

    /// Shown instead of an endless spinner when camera access is off or there is no camera.
    private var cameraUnavailableView: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color(.systemGray6))
            .overlay {
                VStack(spacing: 14) {
                    Image(systemName: camera.status == .denied ? "video.slash" : "camera.badge.ellipsis")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(camera.status == .denied ? "Camera access is off" : "No camera available")
                        .font(.headline)
                    Text("You can still choose a photo of your monitor or scale, or type the numbers in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if camera.status == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(28)
            }
    }

    // MARK: - Secondary Buttons

    private var photoButton: some View {
        PhotosPicker(selection: $pickedPhoto, matching: .images) {
            secondaryButtonLabel("Photo", systemImage: "photo.on.rectangle")
        }
        .accessibilityLabel("Choose a photo")
        .accessibilityHint("Reads a photo of your monitor or scale from your library")
    }

    private var manualEntryButton: some View {
        Menu {
            Button("Blood Pressure", systemImage: "heart.fill") { onEnterManually(.bloodPressure) }
            Button("Weight", systemImage: "scalemass.fill") { onEnterManually(.weightScale) }
        } label: {
            secondaryButtonLabel("Type It", systemImage: "keyboard")
        }
        .accessibilityLabel("Enter a reading by hand")
    }

    private func secondaryButtonLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 12) {
            if showGlareHint {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.orange)
                Text("Glare on the display: tilt your phone a little")
                    .font(.callout)
                    .fontWeight(.medium)
            } else if let device = detectedDevice {
                Image(systemName: device.icon)
                    .foregroundStyle(.green)
                Text("\(device.displayName) detected")
                    .font(.callout)
                    .fontWeight(.medium)
            } else {
                Image(systemName: "viewfinder")
                    .foregroundStyle(.secondary)
                Text("Point at your device and tap capture")
                    .font(.callout)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - Model Loading & Frame Distribution

    private func loadModelAndStart() async {
        // Start camera display IMMEDIATELY — don't wait for model
        // Model loads in parallel so detection indicator appears as soon as it's ready
        async let modelLoad: Void = {
            await self.zsclassifier.load()
            let embeddings = await self.zsclassifier.computeTextEmbeddings(
                promptArr: healthDevicePrompt.fullPrompts()
            )
            await MainActor.run {
                self.textEmbeddings = embeddings
                self.isModelLoaded = true
            }
        }()

        async let framesStarted: Void = distributeVideoFrames()

        // Both run concurrently — camera shows instantly, model loads in background
        await modelLoad
        await framesStarted
    }

    private func distributeVideoFrames() async {
        let frames = AsyncStream<CMSampleBuffer>(bufferingPolicy: .bufferingNewest(1)) {
            camera.attach(continuation: $0)
        }

        var framesToClassifyContinuation: AsyncStream<CVImageBuffer>.Continuation!
        let framesToClassify = AsyncStream<CVImageBuffer>(bufferingPolicy: .bufferingNewest(1)) {
            framesToClassifyContinuation = $0
        }

        var framesToDisplayContinuation: AsyncStream<CVImageBuffer>.Continuation!
        let framesToDisplay = AsyncStream<CVImageBuffer>(bufferingPolicy: .bufferingNewest(1)) {
            framesToDisplayContinuation = $0
        }
        self.framesToDisplay = framesToDisplay

        guard let framesToClassifyContinuation, let framesToDisplayContinuation else { return }

        async let distributeFrames: () = {
            [framesToClassifyContinuation, framesToDisplayContinuation] in
            var frameCount = 0
            for await sampleBuffer in frames {
                if let frame = sampleBuffer.imageBuffer {
                    framesToClassifyContinuation.yield(frame)
                    framesToDisplayContinuation.yield(frame)
                    // Score every 4th frame for glare (about 8 a second).
                    frameCount += 1
                    if frameCount % 4 == 0 {
                        let glare = FrameQuality.glareFraction(frame)
                        recentFrames.add(frame, glare: glare)
                        await MainActor.run { noteGlare(glare) }
                    }
                }
            }
            await MainActor.run {
                self.framesToDisplay = nil
                self.camera.detatch()
            }
            framesToClassifyContinuation.finish()
            framesToDisplayContinuation.finish()
        }()

        async let classifyFrames: () = {
            for await frame in framesToClassify {
                await classifyFrame(frame)
            }
        }()

        await distributeFrames
        await classifyFrames
    }

    /// Debounced so the hint doesn't flicker: three glary samples in a row show it, three
    /// clean ones hide it.
    private func noteGlare(_ glare: Double) {
        let glary = glare > FrameQuality.glareHintThreshold
        glareStreak = glary ? max(1, glareStreak + 1) : min(-1, glareStreak - 1)
        if glareStreak >= 3, !showGlareHint {
            withAnimation { showGlareHint = true }
        } else if glareStreak <= -3, showGlareHint {
            withAnimation { showGlareHint = false }
        }
    }

    // MARK: - Classification (detection indicator only — does NOT trigger capture)

    private func classifyFrame(_ frame: CVPixelBuffer) async {
        guard !textEmbeddings.isEmpty else { return }

        guard let output = await zsclassifier.computeImageEmbeddings(frame: frame) else {
            return
        }

        let predictions = zip(textEmbeddings, healthDevicePrompt.classNames)
            .map { (textEmbedding, className) in
                let similarity = zsclassifier.cosineSimilarity(output.embedding, textEmbedding)
                return DisplayPrediction(className: className, cosineSimilarity: similarity)
            }

        await MainActor.run {
            self.latestFrame = frame
            updateDetectionIndicator(predictions: predictions)
        }
    }

    /// Update the visual detection indicator — green border + status text.
    /// This does NOT trigger any capture or transition — purely visual feedback.
    private func updateDetectionIndicator(predictions: [DisplayPrediction]) {
        guard let best = predictions.max(by: { $0.cosineSimilarity < $1.cosineSimilarity }),
              best.cosineSimilarity >= detectionConfidenceThreshold
        else {
            detectedDevice = nil
            return
        }

        let device: DeviceType = best.className == DeviceType.bloodPressure.rawValue
            ? .bloodPressure : .weightScale
        detectedDevice = device
    }
}
