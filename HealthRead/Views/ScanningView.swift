import AVFoundation
import CoreML
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
    let onFrameCaptured: (CVPixelBuffer) -> Void

    // MobileCLIP state (for detection indicator only)
    @State private var zsclassifier = ZSImageClassification(model: defaultModel.factory())
    @State private var textEmbeddings: [MLMultiArray] = []
    @State private var framesToDisplay: AsyncStream<CVImageBuffer>?
    @State private var detectedDevice: DeviceType?
    @State private var isModelLoaded = false
    @State private var pulseAnimation = false
    @State private var latestFrame: CVPixelBuffer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 60)

                // Camera viewport
                ZStack {
                    if let framesToDisplay {
                        VideoFrameView(frames: framesToDisplay, backCamera: $backCamera)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
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

                // Capture button
                captureButton
                    .padding(.bottom, 24)
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

    // MARK: - Capture Button

    private var captureButton: some View {
        Button {
            guard let frame = latestFrame else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            onFrameCaptured(frame)
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
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: 12) {
            if let device = detectedDevice {
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
            for await sampleBuffer in frames {
                if let frame = sampleBuffer.imageBuffer {
                    framesToClassifyContinuation.yield(frame)
                    framesToDisplayContinuation.yield(frame)
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
