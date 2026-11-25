import CoreGraphics
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
    case weight(WeightReading)
    case noDeviceDetected
    /// The reader could not run or failed; the coordinator moves on to the next reader.
    case error(String)
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
    /// Try a cloud reader first, then fall back to on-device readers.
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
        case .cloudAssisted: return [.claude, .applePrivateCloud, .appleOnDevice, .textRecognition]
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
    - unit is "kg" or "lbs" from the unit shown on the display; if no unit is visible, use "lbs"

    If the photo does not clearly show either device's display, report device_type "none".
    Ignore clocks, dates, memory numbers and printed text that is not part of the reading.
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
            return .weight(WeightReading(weight: weight_value, unit: weight_unit == "kg" ? .kg : .lbs))
        default:
            return .noDeviceDetected
        }
    }
}

// MARK: - Coordinator

/// Tries the readers for the chosen mode in order and returns the first usable result.
/// A reader that is unavailable or errors (offline, no credit, unsupported phone) is skipped;
/// "no device in the photo" is trusted and returned as is.
actor ReadingCoordinator {

    private let claude = ClaudeReader()
    private let textRecognition = TextRecognitionReader()

    func read(_ image: CGImage, mode: ReadingMode, hint: DeviceType?) async -> (ReadingResult, ReaderKind?) {
        var lastError = "No reader is available on this iPhone."
        for kind in mode.readers {
            let result: ReadingResult
            switch kind {
            case .claude:
                result = await claude.read(image)
            case .applePrivateCloud, .appleOnDevice:
                result = await AppleModelReader.read(image, privateCloud: kind == .applePrivateCloud)
            case .textRecognition:
                result = await textRecognition.read(image, hint: hint)
            }
            if case .error(let message) = result {
                print("Reader \(kind.rawValue) skipped: \(message)")
                lastError = message
                continue
            }
            return (result, kind)
        }
        return (.error(lastError), nil)
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

/// Sends one JPEG to HealthRead's reading service, which calls Claude with a key that
/// never leaves AWS. The app holds no API key.
struct ClaudeReader {

    /// Public HTTPS endpoint of the reading service (an AWS Lambda function URL).
    /// Not a secret: it only accepts a photo and returns the reading JSON.
    /// Filled in after the function is deployed; nil means cloud reading is off in this build.
    static let serviceURL: URL? = nil

    static var isConfigured: Bool { serviceURL != nil }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func read(_ image: CGImage) async -> ReadingResult {
        guard let url = Self.serviceURL else {
            return .error("Cloud reading isn\u{2019}t set up in this build.")
        }
        guard let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            return .error("Couldn\u{2019}t prepare the photo.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-HealthRead-Client")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["image_jpeg_base64": jpeg.base64EncodedString()])
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .error("No response from the reading service.")
            }
            switch http.statusCode {
            case 200:
                return try JSONDecoder().decode(ModelReading.self, from: data).result
            case 429:
                return .error("The reading service is busy. Using the on-device reader instead.")
            default:
                return .error("The reading service returned an error (\(http.statusCode)).")
            }
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .error("No internet connection.")
        } catch {
            return .error("Cloud reading failed: \(error.localizedDescription)")
        }
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
            return .error(reason)
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
    @Guide(description: "Weight unit shown on the scale display")
    var weightUnit: AppleWeightUnit?

    var result: ReadingResult {
        switch deviceType {
        case .bloodPressureMonitor:
            guard let systolic, let diastolic else {
                return .error("Couldn\u{2019}t read both blood pressure numbers from the display.")
            }
            return .bloodPressure(BloodPressureReading(systolic: systolic, diastolic: diastolic, pulse: pulse))
        case .weightScale:
            guard let weightValue else { return .error("Couldn\u{2019}t read the weight from the display.") }
            return .weight(WeightReading(weight: weightValue, unit: weightUnit == .kg ? .kg : .lbs))
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
            return .error("Text recognition found no numbers on the display.")
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
            return .weight(WeightReading(weight: weight, unit: joined.contains("kg") ? .kg : .lbs))
        }
        return .error("Text recognition couldn\u{2019}t read this display. Seven-segment digits are hard for it; try again closer and without glare, or type the numbers.")
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
