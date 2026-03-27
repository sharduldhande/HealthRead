import Vision
import CoreImage
import UIKit

/// Actor-isolated OCR service using Apple Vision for reading numbers off health devices.
actor OCRService {

    private let ciContext = CIContext()

    /// Perform text recognition on a frozen camera frame.
    /// Tries multiple orientations to handle angled images, picks the one with the most results.
    func recognizeText(from pixelBuffer: CVPixelBuffer) async -> [String] {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Try multiple orientations — camera frames may be rotated or at an angle
        let orientations: [CGImagePropertyOrientation] = [.right, .up, .left, .down]
        var bestResults: [String] = []
        var bestNumberCount = 0

        for orientation in orientations {
            let oriented = ciImage.oriented(orientation)
            guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
                continue
            }

            let results = await performRecognition(on: cgImage, level: .accurate)
            // Score by how many digit-containing strings we found (more digits = better for health readings)
            let numberCount = results.filter { $0.range(of: #"\d"#, options: .regularExpression) != nil }.count

            print("OCR orientation \(orientation.rawValue): \(results) — \(numberCount) number strings")

            if numberCount > bestNumberCount {
                bestNumberCount = numberCount
                bestResults = results
            }
        }

        if !bestResults.isEmpty {
            print("OCR best result (\(bestNumberCount) numbers): \(bestResults)")
            return bestResults
        }

        // Last resort: fast recognition with default orientation
        let oriented = ciImage.oriented(.right)
        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
            return []
        }
        let fastResults = await performRecognition(on: cgImage, level: .fast)
        print("OCR (fast fallback): \(fastResults)")
        return fastResults
    }

    private func performRecognition(on cgImage: CGImage, level: VNRequestTextRecognitionLevel) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    print("OCR error: \(error)")
                    continuation.resume(returning: [])
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                // Get top 3 candidates per observation for better number matching
                let texts = observations.flatMap { obs in
                    obs.topCandidates(3).map { $0.string }
                }

                continuation.resume(returning: texts)
            }

            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            // Allow numbers and common BP/weight characters
            request.customWords = ["mmHg", "SYS", "DIA", "PUL", "bpm", "lbs", "kg"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("OCR perform failed: \(error)")
                continuation.resume(returning: [])
            }
        }
    }

    /// Parse OCR results for a blood pressure monitor.
    func parseBloodPressure(from texts: [String]) -> BloodPressureReading? {
        print("Parsing BP from texts: \(texts)")

        // Collect ALL numbers from all text fragments
        let allNumbers = extractAllNumbers(from: texts)
        print("All extracted numbers: \(allNumbers)")

        let allText = texts.joined(separator: " ")

        // Strategy 1: Slash pattern "120/80"
        let slashPattern = #"(\d{2,3})\s*/\s*(\d{2,3})"#
        if let match = allText.range(of: slashPattern, options: .regularExpression) {
            let matched = String(allText[match])
            let parts = matched.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let sys = Int(parts[0]),
               let dia = Int(parts[1]),
               isValidBP(systolic: sys, diastolic: dia) {
                let pulse = findPulse(in: allNumbers, excluding: [sys, dia])
                print("BP parsed (slash): \(sys)/\(dia) pulse:\(pulse ?? -1)")
                return BloodPressureReading(systolic: sys, diastolic: dia, pulse: pulse)
            }
        }

        // Strategy 2: Look for numbers in typical BP range
        // Filter to 2-3 digit numbers that could be BP values
        let bpRange = allNumbers.filter { $0 >= 40 && $0 <= 250 }
        let pulseRange = allNumbers.filter { $0 >= 30 && $0 <= 200 }

        if bpRange.count >= 2 {
            let sorted = bpRange.sorted(by: >)
            let sys = sorted[0]
            let dia = sorted[1]
            if isValidBP(systolic: sys, diastolic: dia) {
                let pulse = pulseRange.first { $0 != sys && $0 != dia }
                print("BP parsed (range): \(sys)/\(dia) pulse:\(pulse ?? -1)")
                return BloodPressureReading(systolic: sys, diastolic: dia, pulse: pulse)
            }
        }

        // Strategy 3: If we have exactly 3 numbers, assume sys/dia/pulse
        if allNumbers.count >= 3 {
            let sorted = allNumbers.sorted(by: >)
            // Try first three as sys, dia, pulse
            for i in 0..<sorted.count {
                for j in (i+1)..<sorted.count {
                    let sys = sorted[i]
                    let dia = sorted[j]
                    if isValidBP(systolic: sys, diastolic: dia) {
                        let pulse = allNumbers.first { $0 != sys && $0 != dia && $0 >= 30 && $0 <= 200 }
                        print("BP parsed (combo): \(sys)/\(dia) pulse:\(pulse ?? -1)")
                        return BloodPressureReading(systolic: sys, diastolic: dia, pulse: pulse)
                    }
                }
            }
        }

        print("BP parsing failed — no valid reading found")
        return nil
    }

    /// Parse OCR results for a weight scale.
    func parseWeight(from texts: [String]) -> Double? {
        print("Parsing weight from texts: \(texts)")

        let allText = texts.joined(separator: " ")

        // Try decimal pattern first: "185.4"
        let decimalPattern = #"\d{2,3}\.\d{1,2}"#
        var searchStart = allText.startIndex
        while searchStart < allText.endIndex {
            let searchRange = searchStart..<allText.endIndex
            if let range = allText.range(of: decimalPattern, options: .regularExpression, range: searchRange) {
                let matched = String(allText[range])
                if let weight = Double(matched), isValidWeight(weight) {
                    print("Weight parsed (decimal): \(weight)")
                    return weight
                }
                searchStart = range.upperBound
            } else {
                break
            }
        }

        // Try whole numbers in weight range
        let numbers = extractAllNumbers(from: texts)
        if let weight = numbers.first(where: { isValidWeight(Double($0)) }) {
            print("Weight parsed (whole): \(weight)")
            return Double(weight)
        }

        print("Weight parsing failed")
        return nil
    }

    // MARK: - Private Helpers

    /// Extract all integer numbers from an array of text strings
    private func extractAllNumbers(from texts: [String]) -> [Int] {
        let pattern = #"\d+"#
        var results: [Int] = []
        for text in texts {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: pattern, options: .regularExpression, range: searchRange) {
                if let num = Int(text[range]) {
                    results.append(num)
                }
                searchRange = range.upperBound..<text.endIndex
            }
        }
        // Deduplicate while preserving order
        var seen = Set<Int>()
        return results.filter { seen.insert($0).inserted }
    }

    private func isValidBP(systolic: Int, diastolic: Int) -> Bool {
        systolic > diastolic &&
        systolic >= 60 && systolic <= 250 &&
        diastolic >= 30 && diastolic <= 150
    }

    private func isValidWeight(_ weight: Double) -> Bool {
        weight >= 20 && weight <= 700
    }

    private func findPulse(in numbers: [Int], excluding: [Int]) -> Int? {
        numbers.first { num in
            num >= 30 && num <= 200 && !excluding.contains(num)
        }
    }
}
