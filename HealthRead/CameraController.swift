//
// For licensing see accompanying LICENSE file.
// Copyright (C) 2024 Apple Inc. All Rights Reserved.
//

import AVFoundation
import CoreImage
import UIKit

@Observable
class CameraController: NSObject {

    private var framesContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    public var backCamera = true {
        didSet {
            stop()
            start()
        }
    }

    /// What the camera viewport should show. Updated on the main thread.
    enum Status: Equatable {
        case starting, running, denied, unavailable
    }
    public private(set) var status: Status = .starting

    private var permissionGranted = false
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?

    /// Current zoom, 1 = no zoom. Updated on the main thread.
    public private(set) var zoomFactor: CGFloat = 1
    /// Past this, digital zoom only blurs the display's digits.
    public static let maxZoom: CGFloat = 5

    /// Zooms the camera itself, so the captured frame (what gets read) is zoomed too and
    /// gains detail from the full-resolution sensor.
    public func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard let videoDevice else { return }
            let upper = min(videoDevice.maxAvailableVideoZoomFactor, Self.maxZoom)
            let clamped = max(videoDevice.minAvailableVideoZoomFactor, min(factor, upper))
            do {
                try videoDevice.lockForConfiguration()
                videoDevice.videoZoomFactor = clamped
                videoDevice.unlockForConfiguration()
            } catch {
                return
            }
            DispatchQueue.main.async { self.zoomFactor = clamped }
        }
    }
    private let sessionQueue = DispatchQueue(label: "sessionQueue")

    public func attach(continuation: AsyncStream<CMSampleBuffer>.Continuation) {
        sessionQueue.async {
            self.framesContinuation = continuation
        }
    }

    public func detatch() {
        sessionQueue.async {
            self.framesContinuation = nil
        }
    }

    public func stop() {
        sessionQueue.sync { [self] in
            captureSession?.stopRunning()
            captureSession = nil
            videoDevice = nil
        }

    }

    public func start() {
        // Ask for camera access first and hold the session queue until the user answers,
        // so the session isn't configured before permission exists.
        sessionQueue.async { [self] in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                permissionGranted = true
            case .notDetermined:
                sessionQueue.suspend()
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    self.permissionGranted = granted
                    self.sessionQueue.resume()
                }
            default:
                permissionGranted = false
            }
        }

        sessionQueue.async { [self] in
            guard permissionGranted else {
                setStatus(.denied)
                return
            }
            let captureSession = AVCaptureSession()
            self.captureSession = captureSession
            guard setupCaptureSession(position: backCamera ? .back : .front) else {
                self.captureSession = nil
                setStatus(.unavailable)
                return
            }
            captureSession.startRunning()
            setStatus(.running)
        }
    }

    /// Displays sit behind glossy plastic: expose a little darker so reflections don't wash
    /// out and the dark LCD segments stand out, and favor close-range focus.
    private func configureForDisplays(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let bias = max(device.minExposureTargetBias, min(-0.7, device.maxExposureTargetBias))
            device.setExposureTargetBias(bias)
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        } catch {
            print("Couldn't configure the camera for displays: \(error)")
        }
    }

    private func setStatus(_ newStatus: Status) {
        DispatchQueue.main.async { self.status = newStatus }
    }

    private func setOrientation(_ orientation: UIDeviceOrientation) {
        guard let captureSession else { return }

        let angle: Double?
        switch orientation {
        case .unknown, .faceDown:
            angle = nil
        case .portrait, .faceUp:
            angle = 90
        case .portraitUpsideDown:
            angle = 270
        case .landscapeLeft:
            angle = 0
        case .landscapeRight:
            angle = 180
        @unknown default:
            angle = nil
        }

        if let angle {
            for output in captureSession.outputs {
                output.connection(with: .video)?.videoRotationAngle = angle
            }
        }
    }

    /// Configures inputs and outputs. Returns false when there is no usable camera
    /// (for example in the Simulator).
    func setupCaptureSession(position: AVCaptureDevice.Position) -> Bool {
        guard let captureSession else { return false }

        let videoOutput = AVCaptureVideoDataOutput()

        let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: position)

        guard
            let videoDevice = videoDeviceDiscoverySession.devices.first
        else {
            print("Unable to find video device")
            return false
        }
        guard let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
            print("Unable to create AVCaptureDeviceInput")
            return false
        }
        guard captureSession.canAddInput(videoDeviceInput) else {
            print("Unable to add input")
            return false
        }
        captureSession.addInput(videoDeviceInput)
        self.videoDevice = videoDevice
        DispatchQueue.main.async { self.zoomFactor = 1 }

        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sampleBufferQueue"))
        captureSession.addOutput(videoOutput)
        // Seven-segment digits need pixels: 640x480 left each digit about 30 px tall, and
        // glare costs more of a small image. The photo sent for reading is capped at 1600 px.
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .vga640x480]
        where captureSession.canSetSessionPreset(preset) {
            captureSession.sessionPreset = preset
            break
        }
        configureForDisplays(videoDevice)

        // The app runs in portrait only, so frames are always rotated upright for portrait.
        // (UIDevice.current.orientation is .unknown unless orientation updates are on, and
        // .unknown left frames in the sensor's landscape angle, 90° off.)
        setOrientation(.portrait)
        return true
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if sampleBuffer.isValid && sampleBuffer.imageBuffer != nil {
            framesContinuation?.yield(sampleBuffer)
        }
    }
}
