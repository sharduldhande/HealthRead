import CoreGraphics
import CryptoKit
import DeviceCheck
import Foundation
import ImageIO
import UIKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Results

/// What a reader found in a photo.
enum ReadingResult {
    case bloodPressure(BloodPressureReading)
    /// `unit` is nil when the display shows no unit; the confirm screen then asks for it.
    case weight(Double, unit: WeightUnit?)
    case noDeviceDetected
    /// The reader could not run or failed; the coordinator moves on to the next reader.
    /// `category` is a short fixed label for analytics (never contains reading data).
    case error(String, category: String = "failed")
}

/// The reader that produced a set of numbers. Shown on the confirm screen.
enum ReaderKind: String, CaseIterable, Identifiable {
    case claude
    case applePrivateCloud
    case appleOnDevice
    case textRecognition

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .applePrivateCloud: return "Apple Private Cloud Compute"
        case .appleOnDevice: return "Apple Intelligence (on device)"
        case .textRecognition: return "Apple text recognition (on device)"
        }
    }

    var runsOnDevice: Bool {
        self == .appleOnDevice || self == .textRecognition
    }
}

/// The user's choice in onboarding and Settings.
enum ReadingMode: String, CaseIterable, Identifiable {
    /// Photos never leave the phone.
    case onDevice
    /// Apple's models first (Private Cloud Compute, then on-device), then Claude, then text recognition.
    case cloudAssisted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "Fully On-Device"
        case .cloudAssisted: return "Cloud Assisted"
        }
    }

    /// Readers to try, in order.
    var readers: [ReaderKind] {
        switch self {
        case .onDevice: return [.appleOnDevice, .textRecognition]
        case .cloudAssisted: return [.applePrivateCloud, .appleOnDevice, .claude, .textRecognition]
        }
    }

    static let storageKey = "readingMode"
    static let chosenKey = "didChooseReadingMode"
}

// MARK: - Shared prompt and output shape

/// The instructions every model-based reader gets, so results are comparable.
enum ReadingPrompt {
    static let instructions = """
    You read the display of a home health device in a photo and report the numbers exactly as shown.

    If the photo shows a BLOOD PRESSURE MONITOR:
    - systolic is the value labeled SYS (usually the top, largest row)
    - diastolic is the value labeled DIA (usually the middle row)
    - pulse is the value labeled PUL, PULSE or with a heart symbol (usually the bottom row), if shown
    - Read each value from its label. Do not reorder values or guess missing digits.

    If the photo shows a BATHROOM WEIGHT SCALE:
    - weight is the number on the display, including any decimal point
    - unit is "kg" or "lbs" only if that unit is shown on the display; if no unit is visible, leave the unit empty (never guess it)

    If the photo does not clearly show either device's display, report device_type "none".
    Ignore clocks, dates, memory numbers and printed text that is not part of the reading.
    If glare, a reflection, blur or the edge of the photo hides any digit of a value, report that value as missing. Never guess a digit: a missing number is safe, a wrong one is not.
    """
}

/// Model output in the shared JSON shape. Claude's service returns this shape directly.
struct ModelReading: Decodable {
    let device_type: String
    let systolic: Int?
    let diastolic: Int?
    let pulse: Int?
    let weight_value: Double?
    let weight_unit: String?
    /// Values the model read but isn't sure of. Analytics only (field names, never numbers).
    let unclear: [String]?

    var result: ReadingResult {
        switch device_type {
        case "blood_pressure":
            guard let systolic, let diastolic else {
                return .error("Couldn\u{2019}t read both blood pressure numbers from the display.")
            }
            return .bloodPressure(BloodPressureReading(systolic: systolic, diastolic: diastolic, pulse: pulse))
        case "weight_scale":
            guard let weight_value else {
                return .error("Couldn\u{2019}t read the weight from the display.")
            }
            return .weight(weight_value, unit: weight_unit.flatMap(WeightUnit.init(rawValue:)))
        default:
            return .noDeviceDetected
        }
    }
}

// MARK: - Coordinator

/// Tries the readers for the chosen mode in order and returns the first usable result.
/// A reader that is unavailable or errors (offline, no credit, unsupported phone) is skipped.
/// "No device in the photo" ends the attempt only when Claude or the last reader says it;
/// from Apple's models it moves on, since their accuracy on these displays is unproven.
actor ReadingCoordinator {

    private let claude = ClaudeReader()
    private let textRecognition = TextRecognitionReader()

    /// One reader's turn, for analytics: which reader, how it ended, how long it took.
    struct Attempt {
        let reader: ReaderKind
        let outcome: String   // "read", "no_device" or the error category
        let ms: Int

        var analyticsValue: [String: Any] { ["reader": reader.rawValue, "outcome": outcome, "ms": ms] }
    }

    struct Outcome {
        let result: ReadingResult
        let reader: ReaderKind?
        let attempts: [Attempt]
    }

    func read(_ image: CGImage, mode: ReadingMode, hint: DeviceType?) async -> Outcome {
        var lastError = "No reader is available on this iPhone."
        var sawNoDevice: ReaderKind?
        var attempts: [Attempt] = []
        for kind in mode.readers {
            let started = Date()
            let result: ReadingResult
            switch kind {
            case .claude:
                result = await claude.read(image)
            case .applePrivateCloud, .appleOnDevice:
                result = await AppleModelReader.read(image, privateCloud: kind == .applePrivateCloud)
            case .textRecognition:
                result = await textRecognition.read(image, hint: hint)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .error(let message, let category):
                print("Reader \(kind.rawValue) skipped: \(message)")
                attempts.append(Attempt(reader: kind, outcome: category, ms: ms))
                lastError = message
                continue
            case .noDeviceDetected:
                attempts.append(Attempt(reader: kind, outcome: "no_device", ms: ms))
                if kind == .applePrivateCloud || kind == .appleOnDevice {
                    print("Reader \(kind.rawValue) saw no device; asking the next reader")
                    sawNoDevice = kind
                    continue
                }
            case .bloodPressure, .weight:
                attempts.append(Attempt(reader: kind, outcome: "read", ms: ms))
            }
            return Outcome(result: result, reader: kind, attempts: attempts)
        }
        if let sawNoDevice {
            return Outcome(result: .noDeviceDetected, reader: sawNoDevice, attempts: attempts)
        }
        return Outcome(result: .error(lastError), reader: nil, attempts: attempts)
    }

    /// For Settings: which readers can run right now on this phone.
    nonisolated static func availability(of kind: ReaderKind) -> String? {
        switch kind {
        case .claude:
            return ClaudeReader.isConfigured ? nil : "Not set up in this build"
        case .applePrivateCloud, .appleOnDevice:
            return AppleModelReader.unavailableReason(privateCloud: kind == .applePrivateCloud)
        case .textRecognition:
            return nil
        }
    }
}

// MARK: - Claude (through HealthRead's AWS function)

/// Sends one JPEG to HealthRead's reading service (an AWS function that signs in to Claude
/// with workload identity federation). The app holds no API key; each request is signed
/// with an App Attest key so only genuine installs can use the service.
struct ClaudeReader {

    /// Public HTTPS endpoint of the reading service (an AWS Lambda function URL).
    /// Not a secret: it only accepts a photo and returns the reading JSON.
    /// AWS Lambda function URL from server/reading-service (us-east-2). nil turns cloud reading off.
    static let serviceURL = URL(string: "https://hiwf6xedh2z2jwuhsyx7t5rm5e0sqbwv.lambda-url.us-east-2.on.aws/")

    static var isConfigured: Bool { serviceURL != nil }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
    private var session: URLSession { Self.session }

    /// Does the slow one-time work before the shutter instead of after it: registers this
    /// install with App Attest if it hasn't yet, and wakes the server (a GET gets an instant
    /// 405 with no database or Claude work, but starts the function). Errors are ignored;
    /// `read` repeats whatever is still missing.
    static func prepare() async {
        guard let baseURL = serviceURL, DCAppAttestService.shared.isSupported else { return }
        _ = try? await AppAttestClient.shared.attestedKeyID(baseURL: baseURL, session: session)
        _ = try? await session.data(from: baseURL.appending(path: "warm"))
    }

    func read(_ image: CGImage) async -> ReadingResult {
        guard let baseURL = Self.serviceURL else {
            return .error("Cloud reading isn\u{2019}t set up in this build.", category: "not_configured")
        }
        guard DCAppAttestService.shared.isSupported else {
            // Simulator, or a device without the Secure Enclave support App Attest needs.
            return .error("Cloud reading needs App Attest, which this device doesn\u{2019}t support.", category: "attest_unsupported")
        }
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8),
              let body = try? JSONSerialization.data(withJSONObject: ["image_jpeg_base64": jpeg.base64EncodedString()])
        else {
            return .error("Couldn\u{2019}t prepare the photo.")
        }

        // At most two tries: the second after re-attesting, if the server no longer knows our key.
        for attempt in 0..<2 {
            let keyID: String
            let assertion: Data
            do {
                keyID = try await AppAttestClient.shared.attestedKeyID(baseURL: baseURL, session: session)
                assertion = try await DCAppAttestService.shared.generateAssertion(
                    keyID, clientDataHash: Data(SHA256.hash(data: body)))
            } catch let error as URLError where error.code == .notConnectedToInternet {
                return .error("No internet connection.", category: "offline")
            } catch {
                await AppAttestClient.shared.reset()
                if attempt == 0 { continue }
                return .error("Couldn\u{2019}t verify this copy of HealthRead: \(error.localizedDescription)", category: "attest_failed")
            }

            var request = URLRequest(url: baseURL.appending(path: "read"))
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(keyID, forHTTPHeaderField: "X-AppAttest-Key-Id")
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-AppAttest-Assertion")
            request.setValue(Analytics.installID, forHTTPHeaderField: "X-HealthRead-Install-Id")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    return try JSONDecoder().decode(ModelReading.self, from: data).result
                case 401:
                    await AppAttestClient.shared.reset()
                    if attempt == 0 { continue }
                    return .error("The reading service didn\u{2019}t accept this copy of HealthRead.", category: "attest_rejected")
                case 422:
                    return .error("Claude couldn\u{2019}t read this photo.", category: "no_reading")
                case 429:
                    return .error("Cloud reading has hit today\u{2019}s limit. Reading on this iPhone instead.", category: "rate_limited")
                default:
                    return .error("The reading service returned an error (\(status)).", category: "server_error")
                }
            } catch let error as URLError where error.code == .notConnectedToInternet {
                return .error("No internet connection.", category: "offline")
            } catch {
                return .error("Cloud reading failed: \(error.localizedDescription)", category: "network_error")
            }
        }
        return .error("Couldn\u{2019}t verify this copy of HealthRead.", category: "attest_failed")
    }
}

/// Apple App Attest key for talking to the reading service. The private key never leaves
/// the Secure Enclave; the service checks Apple's certificate once (attestation), then a
/// signature on every request (assertion), so only genuine HealthRead installs can use it.
actor AppAttestClient {

    static let shared = AppAttestClient()

    private let keyIDKey = "appAttestKeyID"
    private let attestedKey = "appAttestKeyAttested"

    /// A key ID the server has accepted, creating and attesting one if needed.
    func attestedKeyID(baseURL: URL, session: URLSession) async throws -> String {
        let defaults = UserDefaults.standard
        if let keyID = defaults.string(forKey: keyIDKey), defaults.bool(forKey: attestedKey) {
            return keyID
        }
        let keyID = try await DCAppAttestService.shared.generateKey()

        // 1. One-time challenge from the server.
        var challengeRequest = URLRequest(url: baseURL.appending(path: "challenge"))
        challengeRequest.httpMethod = "POST"
        let (challengeData, _) = try await session.data(for: challengeRequest)
        guard let challengeB64 = (try JSONSerialization.jsonObject(with: challengeData) as? [String: Any])?["challenge"] as? String,
              let challenge = Data(base64Encoded: challengeB64)
        else { throw URLError(.badServerResponse) }

        // 2. Apple certifies the key, bound to the challenge.
        let attestation = try await DCAppAttestService.shared.attestKey(
            keyID, clientDataHash: Data(SHA256.hash(data: challenge)))

        // 3. The server checks Apple's certificate and remembers the key.
        var attestRequest = URLRequest(url: baseURL.appending(path: "attest"))
        attestRequest.httpMethod = "POST"
        attestRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        attestRequest.setValue(Analytics.installID, forHTTPHeaderField: "X-HealthRead-Install-Id")
        attestRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "key_id": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challengeB64,
        ])
        let (_, response) = try await session.data(for: attestRequest)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }

        defaults.set(keyID, forKey: keyIDKey)
        defaults.set(true, forKey: attestedKey)
        return keyID
    }

    /// Forget the key so the next request creates and attests a new one.
    func reset() {
        UserDefaults.standard.removeObject(forKey: keyIDKey)
        UserDefaults.standard.removeObject(forKey: attestedKey)
    }
}

// MARK: - Apple Foundation Models (on-device or Private Cloud Compute)

enum AppleModelReader {

    static func unavailableReason(privateCloud: Bool) -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return "Needs iOS 27" }
        if privateCloud {
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                return model.capabilities.contains(.vision) ? nil : "Doesn\u{2019}t accept images"
            case .unavailable(.deviceNotEligible):
                return "Needs an Apple Intelligence iPhone"
            case .unavailable:
                return "Not ready yet"
            }
        } else {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return model.capabilities.contains(.vision) ? nil : "Doesn\u{2019}t accept images"
            case .unavailable(.deviceNotEligible):
                return "Needs an Apple Intelligence iPhone"
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off"
            case .unavailable:
                return "Model is still downloading"
            }
        }
        #else
        return "Not supported by this build"
        #endif
    }

    static func read(_ image: CGImage, privateCloud: Bool) async -> ReadingResult {
        if let reason = unavailableReason(privateCloud: privateCloud) {
            return .error(reason, category: "unavailable")
        }
        #if canImport(FoundationModels)
        guard #available(iOS 27.0, *) else { return .error("Needs iOS 27") }
        do {
            let session: LanguageModelSession = privateCloud
                ? LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: ReadingPrompt.instructions)
                : LanguageModelSession(model: SystemLanguageModel.default, instructions: ReadingPrompt.instructions)
            let response = try await session.respond(generating: AppleDisplayReading.self) {
                "Read the display in this photo."
                Attachment(image)
            }
            return response.content.result
        } catch {
            return .error("Apple model failed: \(error.localizedDescription)")
        }
        #else
        return .error("Not supported by this build")
        #endif
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
@Generable
enum AppleDeviceKind {
    case bloodPressureMonitor
    case weightScale
    case none
}

@available(iOS 27.0, *)
@Generable
enum AppleWeightUnit {
    case kg
    case lbs
}

/// Typed output for Apple's models (guided generation), mirroring `ModelReading`.
@available(iOS 27.0, *)
@Generable
struct AppleDisplayReading {
    @Guide(description: "Which device's display is in the photo")
    var deviceType: AppleDeviceKind
    @Guide(description: "Blood pressure value labeled SYS, in mmHg")
    var systolic: Int?
    @Guide(description: "Blood pressure value labeled DIA, in mmHg")
    var diastolic: Int?
    @Guide(description: "Pulse in beats per minute, if shown")
    var pulse: Int?
    @Guide(description: "Weight shown on a scale display, including decimals")
    var weightValue: Double?
    @Guide(description: "Weight unit printed on the scale display; empty if no unit is shown")
    var weightUnit: AppleWeightUnit?

    var result: ReadingResult {
        // Apple's models fill optional numbers with 0 instead of leaving them out, so 0 means missing.
        let systolic = systolic.flatMap { $0 > 0 ? $0 : nil }
        let diastolic = diastolic.flatMap { $0 > 0 ? $0 : nil }
        let pulse = pulse.flatMap { $0 > 0 ? $0 : nil }
        let weightValue = weightValue.flatMap { $0 > 0 ? $0 : nil }
        switch deviceType {
        case .bloodPressureMonitor:
            guard let systolic, let diastolic else {
                return .error("Couldn\u{2019}t read both blood pressure numbers from the display.")
            }
            return .bloodPressure(BloodPressureReading(systolic: systolic, diastolic: diastolic, pulse: pulse))
        case .weightScale:
            guard let weightValue else { return .error("Couldn\u{2019}t read the weight from the display.") }
            return .weight(weightValue, unit: weightUnit.map { $0 == .kg ? .kg : .lbs })
        case .none:
            return .noDeviceDetected
        }
    }
}
#endif

// MARK: - Apple text recognition (Vision OCR, works on every iPhone)

/// Reads digits with VNRecognizeTextRequest and picks plausible values. Least accurate on
/// seven-segment displays, but needs no network and no Apple Intelligence.
struct TextRecognitionReader {

    func read(_ image: CGImage, hint: DeviceType?) async -> ReadingResult {
        // Clock times ("7:35") and dates are on most monitors and are never the reading.
        let texts = await recognize(image).map(Self.removingTimesAndDates)
        guard texts.contains(where: { $0.contains(where: \.isNumber) }) else {
            return .error("Text recognition found no numbers on the display.", category: "no_text")
        }
        if hint != .weightScale, let bp = Self.parseBloodPressure(texts) {
            return .bloodPressure(bp)
        }
        // Only report a weight when something says it's a scale; a stray number is more
        // likely a misread blood pressure display, and a wrong guess is worse than none.
        let joined = texts.joined(separator: " ").lowercased()
        // Monitor labels mean this is a blood pressure display, never a scale (the cuff's
        // printed "16.5 in" would otherwise look like a weight).
        let looksLikeMonitor = joined.range(of: #"\b(sys|dia|mmhg|pul)\b"#, options: .regularExpression) != nil
        let looksLikeScale = !looksLikeMonitor && (hint == .weightScale
            || joined.range(of: #"\b(kg|lbs?)\b"#, options: .regularExpression) != nil
            || joined.range(of: #"\d{2,3}\.\d(?!\s*(in|cm))"#, options: .regularExpression) != nil)
        if hint != .bloodPressure, looksLikeScale, let weight = Self.parseWeight(texts) {
            let unit: WeightUnit? = joined.range(of: #"\bkg\b"#, options: .regularExpression) != nil ? .kg
                : joined.range(of: #"\blbs?\b"#, options: .regularExpression) != nil ? .lbs : nil
            return .weight(weight, unit: unit)
        }
        return .error("Text recognition couldn\u{2019}t read this display. Seven-segment digits are hard for it; try again closer and without glare, or type the numbers.", category: "no_reading")
    }

    static func removingTimesAndDates(_ text: String) -> String {
        text
            // times: 7:35, 12:05 PM
            .replacingOccurrences(of: #"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM|am|pm)?"#, with: " ", options: .regularExpression)
            // full dates: 11/25/26, 25.11.2026 (a lone "85/60" is kept: it may be the reading)
            .replacingOccurrences(of: #"\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b"#, with: " ", options: .regularExpression)
    }

    private func recognize(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: observations.flatMap { $0.topCandidates(3).map(\.string) })
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.customWords = ["mmHg", "SYS", "DIA", "PUL", "bpm", "lbs", "kg"]
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    static func parseBloodPressure(_ texts: [String]) -> BloodPressureReading? {
        let numbers = allNumbers(texts)
        let joined = texts.joined(separator: " ")

        // "120/80" written with a slash
        if let range = joined.range(of: #"(\d{2,3})\s*/\s*(\d{2,3})"#, options: .regularExpression) {
            let parts = joined[range].split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, isPlausibleBP(parts[0], parts[1]) {
                return BloodPressureReading(systolic: parts[0], diastolic: parts[1],
                                            pulse: numbers.first { (30...200).contains($0) && !parts.contains($0) })
            }
        }

        // Otherwise: on most monitors SYS > DIA, and both are 2–3 digit numbers.
        let candidates = numbers.filter { (40...250).contains($0) }.sorted(by: >)
        for (i, sys) in candidates.enumerated() {
            for dia in candidates.dropFirst(i + 1) where isPlausibleBP(sys, dia) {
                let pulse = numbers.first { (30...200).contains($0) && $0 != sys && $0 != dia }
                return BloodPressureReading(systolic: sys, diastolic: dia, pulse: pulse)
            }
        }
        return nil
    }

    static func parseWeight(_ texts: [String]) -> Double? {
        let joined = texts.joined(separator: " ")
        var searchStart = joined.startIndex
        while let range = joined.range(of: #"\d{2,3}\.\d{1,2}"#, options: .regularExpression, range: searchStart..<joined.endIndex) {
            if let value = Double(joined[range]), (20...700).contains(value) { return value }
            searchStart = range.upperBound
        }
        return allNumbers(texts).map(Double.init).first { (20...700).contains($0) }
    }

    private static func isPlausibleBP(_ sys: Int, _ dia: Int) -> Bool {
        sys > dia && (60...250).contains(sys) && (30...150).contains(dia) && sys - dia >= 10
    }

    private static func allNumbers(_ texts: [String]) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for text in texts {
            var start = text.startIndex
            while let range = text.range(of: #"\d+"#, options: .regularExpression, range: start..<text.endIndex) {
                if let n = Int(text[range]), seen.insert(n).inserted { result.append(n) }
                start = range.upperBound
            }
        }
        return result
    }
}
