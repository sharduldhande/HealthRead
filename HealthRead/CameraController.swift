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

        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sampleBufferQueue"))
        captureSession.addOutput(videoOutput)
        captureSession.sessionPreset = AVCaptureSession.Preset.vga640x480

        if videoDevice.isContinuityCamera {
            setOrientation(.portrait)
        } else {
            setOrientation(UIDevice.current.orientation)
        }
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
