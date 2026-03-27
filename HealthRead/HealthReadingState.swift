import Foundation
import CoreVideo

/// The app's state machine — drives the entire UI with zero NavigationStack overhead.
enum AppState: Equatable {
    case scanning
    case processing         // Gemini is analyzing the frozen frame
    case confirm(DeviceType)
    case saved(DeviceType)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.scanning, .scanning): return true
        case (.processing, .processing): return true
        case (.confirm(let a), .confirm(let b)): return a == b
        case (.saved(let a), .saved(let b)): return a == b
        default: return false
        }
    }
}

/// The two device types we detect
enum DeviceType: String, Equatable {
    case bloodPressure = "blood pressure monitor"
    case weightScale = "bathroom weight scale"

    var displayName: String {
        switch self {
        case .bloodPressure: return "Blood Pressure"
        case .weightScale: return "Body Weight"
        }
    }

    var icon: String {
        switch self {
        case .bloodPressure: return "heart.fill"
        case .weightScale: return "scalemass.fill"
        }
    }
}
