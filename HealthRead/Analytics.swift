import Foundation
import UIKit

/// Anonymous usage analytics sent to PostHog over HTTPS (no SDK).
///
/// What is sent: which screens and paths are used, which reader ran and whether it worked,
/// timings, app/OS version and device model. Never photos, never reading values, never
/// anything from Apple Health. Events carry a random install ID that isn't linked to a
/// person, and no person profiles are created. Users can turn it off in onboarding or Settings.
///
/// The project key comes from Info.plist (`PostHogAPIKey`), filled at build time from the
/// gitignored `HealthRead/Configuration/Local.xcconfig`. Without it, nothing is sent.
enum Analytics {

    static let enabledKey = "analyticsEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Random ID for this install, so events from one phone can be grouped. Not a person.
    static var installID: String {
        let key = "analyticsInstallID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private static let apiKey: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String ?? ""
        return value.hasPrefix("phc_") ? value : ""
    }()

    private static let endpoint: URL? = {
        let host = (Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String) ?? ""
        guard host.hasPrefix("https://") else { return nil }
        return URL(string: host)?.appending(path: "i/v0/e/")
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private static let common: [String: Any] = {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let bundle = Bundle.main
        return [
            "$lib": "healthread-ios",
            "$process_person_profile": false,
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "$os": "iOS",
            "$os_version": UIDevice.current.systemVersion,
            "$device_model": model,
            // Debug builds (Xcode installs, Simulator) are excluded from dashboards as test traffic.
            "debug_build": isDebugBuild,
        ]
    }()

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Fire-and-forget. Does nothing when disabled or not configured.
    static func capture(_ event: String, _ properties: [String: Any] = [:], force: Bool = false) {
        guard force || isEnabled, !apiKey.isEmpty, let endpoint else { return }
        let payload: [String: Any] = [
            "api_key": apiKey,
            "event": event,
            "distinct_id": installID,
            "properties": common.merging(properties) { _, new in new },
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request).resume()
    }
}
