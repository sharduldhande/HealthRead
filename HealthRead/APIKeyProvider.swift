import Foundation

/// Reads the Gemini API key from Info.plist (injected via Build.xcconfig at build time).
///
/// Setup:
/// 1. Create `Build.xcconfig` in project root with: GEMINI_API_KEY = your-api-key-here
/// 2. In Xcode target Build Settings, set the xcconfig file
/// 3. Add to Info.plist: GeminiAPIKey = $(GEMINI_API_KEY)
enum APIKeyProvider {

    static var geminiAPIKey: String {
        // Try Info.plist first (production path via xcconfig)
        if let key = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String,
           !key.isEmpty,
           key != "$(GEMINI_API_KEY)" {  // Not resolved = xcconfig not set
            return key
        }

        // Fallback: check for a plist file bundled in the app
        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path),
           let key = dict["GeminiAPIKey"] as? String,
           !key.isEmpty {
            return key
        }

        print("⚠️ Gemini API key not configured. Add GEMINI_API_KEY to Build.xcconfig or create Secrets.plist")
        return ""
    }
}
