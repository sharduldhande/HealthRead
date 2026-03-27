import Foundation
import CoreVideo
import UIKit

/// Result of Gemini image analysis
enum GeminiAnalysisResult {
    case bloodPressure(BloodPressureReading)
    case weight(WeightReading)
    case noDeviceDetected
    case error(String)
}

/// Actor-isolated service for analyzing health device images via Gemini 2.5 Flash-Lite.
/// Replaces the old OCR pipeline with a single API call that does both device detection + reading extraction.
actor GeminiService {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    /// Analyze a frozen camera frame — sends to Gemini and returns structured reading data.
    func analyze(frame: CVPixelBuffer) async -> GeminiAnalysisResult {
        // Convert frame to JPEG base64
        guard let base64Image = await pixelBufferToBase64JPEG(frame) else {
            return .error("Failed to convert image")
        }

        let apiKey = APIKeyProvider.geminiAPIKey
        guard !apiKey.isEmpty else {
            return .error("Gemini API key not configured")
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return .error("Invalid API URL")
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody = buildRequestBody(base64Image: base64Image)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return .error("Failed to build request: \(error.localizedDescription)")
        }

        // Send request
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("Invalid response")
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("Gemini API error \(httpResponse.statusCode): \(body)")
                return .error("API error (\(httpResponse.statusCode))")
            }

            return parseResponse(data: data)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            return .error("No internet connection. Please check your network and try again.")
        } catch let error as URLError where error.code == .timedOut {
            return .error("Request timed out. Please try again.")
        } catch {
            return .error("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: - Image Conversion

    private func pixelBufferToBase64JPEG(_ pixelBuffer: CVPixelBuffer) async -> String? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)

        // Save to photo library (must be on main thread)
        await MainActor.run {
            UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
        }

        guard let jpegData = uiImage.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        print("Gemini: Image \(cgImage.width)x\(cgImage.height), JPEG \(jpegData.count / 1024)KB")
        return jpegData.base64EncodedString()
    }

    // MARK: - Request Building

    private func buildRequestBody(base64Image: String) -> [String: Any] {
        let prompt = """
        Look at this photo and determine if it shows a blood pressure monitor or a bathroom weight scale.

        For a BLOOD PRESSURE MONITOR:
        - Read the value labeled "SYS" or displayed at the top — this is the systolic pressure
        - Read the value labeled "DIA" or displayed in the middle — this is the diastolic pressure
        - Read the value labeled "PUL" or "PULSE" or displayed at the bottom — this is the pulse/heart rate
        - Do NOT guess or rearrange values. Read them exactly as labeled on the device display.
        - Systolic is NOT necessarily the largest number. Read what the device shows for each label.

        For a WEIGHT SCALE:
        - Read the number shown on the scale display
        - Determine if the unit is lbs or kg based on any visible unit indicator

        If the image does not clearly show a blood pressure monitor or weight scale, set device_type to "none".
        """

        return [
            "contents": [
                [
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "device_type": [
                            "type": "STRING",
                            "enum": ["blood_pressure", "weight_scale", "none"]
                        ],
                        "systolic": [
                            "type": "INTEGER",
                            "nullable": true
                        ],
                        "diastolic": [
                            "type": "INTEGER",
                            "nullable": true
                        ],
                        "pulse": [
                            "type": "INTEGER",
                            "nullable": true
                        ],
                        "weight_value": [
                            "type": "NUMBER",
                            "nullable": true
                        ],
                        "weight_unit": [
                            "type": "STRING",
                            "enum": ["lbs", "kg"],
                            "nullable": true
                        ]
                    ],
                    "required": ["device_type"]
                ]
            ]
        ]
    }

    // MARK: - Response Parsing

    private func parseResponse(data: Data) -> GeminiAnalysisResult {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String
            else {
                print("Gemini: Failed to extract text from response")
                return .error("Failed to parse API response")
            }

            print("Gemini raw response: \(text)")

            // Parse the JSON text from Gemini
            guard let jsonData = text.data(using: .utf8),
                  let result = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let deviceType = result["device_type"] as? String
            else {
                return .error("Failed to parse reading data")
            }

            switch deviceType {
            case "blood_pressure":
                guard let systolic = result["systolic"] as? Int,
                      let diastolic = result["diastolic"] as? Int
                else {
                    return .error("Could not read blood pressure values from the display")
                }
                let pulse = result["pulse"] as? Int
                let reading = BloodPressureReading(
                    systolic: systolic,
                    diastolic: diastolic,
                    pulse: pulse
                )
                print("Gemini: BP reading \(systolic)/\(diastolic), pulse: \(pulse ?? -1)")
                return .bloodPressure(reading)

            case "weight_scale":
                guard let weightValue = result["weight_value"] as? Double else {
                    return .error("Could not read weight value from the display")
                }
                let unitStr = result["weight_unit"] as? String ?? "lbs"
                let unit: WeightUnit = unitStr == "kg" ? .kg : .lbs
                let reading = WeightReading(weight: weightValue, unit: unit)
                print("Gemini: Weight reading \(weightValue) \(unitStr)")
                return .weight(reading)

            case "none":
                return .noDeviceDetected

            default:
                return .error("Unknown device type: \(deviceType)")
            }
        } catch {
            print("Gemini parse error: \(error)")
            return .error("Failed to parse response: \(error.localizedDescription)")
        }
    }
}
