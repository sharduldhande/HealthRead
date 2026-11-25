import Foundation
import CoreVideo

/// The app's state machine — drives the entire UI with zero NavigationStack overhead.
enum AppState: Equatable {
    case scanning
    case processing         // a reader is analyzing the captured photo
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

/// Where the numbers on the confirm screen came from.
enum ReadingSource: Equatable {
    /// Read from the photo by one of the readers; the user must check them.
    case reader(ReaderKind)
    /// Typed in by the user.
    case manual
}
