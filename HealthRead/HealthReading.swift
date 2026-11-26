import Foundation

/// A blood pressure reading with optional pulse
struct BloodPressureReading: Identifiable {
    let id: UUID
    var systolic: Int
    var diastolic: Int
    var pulse: Int?
    var timestamp: Date = Date()

    init(systolic: Int, diastolic: Int, pulse: Int? = nil, timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.timestamp = timestamp
    }
}

/// A body weight reading
struct WeightReading: Identifiable {
    let id: UUID
    var weight: Double
    var unit: WeightUnit
    var timestamp: Date = Date()

    var weightInKg: Double {
        switch unit {
        case .lbs: return weight * 0.453592
        case .kg: return weight
        }
    }

    init(weight: Double, unit: WeightUnit, timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.weight = weight
        self.unit = unit
        self.timestamp = timestamp
    }
}

enum WeightUnit: String, CaseIterable {
    case lbs = "lbs"
    case kg = "kg"

    /// The person's chosen default, used when a scale's display shows no unit. Empty means
    /// "ask me". Set only on purpose (Settings, or the checkmark on the confirm screen).
    static let defaultKey = "defaultWeightUnit"

    static var savedDefault: WeightUnit? {
        UserDefaults.standard.string(forKey: defaultKey).flatMap(WeightUnit.init(rawValue:))
    }
}

/// Where the weight unit on the confirm screen came from, when the display showed none.
enum WeightUnitNote: Equatable {
    /// The display showed the unit, or the person is typing the reading in.
    case none
    /// No unit on the display and no default: the confirm screen asks.
    case ask
    /// No unit on the display, so the saved default was filled in.
    case usedDefault
}

// MARK: - Blood Pressure Category

/// Category for a blood pressure reading, using the American Heart Association adult
/// thresholds. A reading falls in the highest category either number reaches.
enum BPCategory {
    case low, normal, elevated, stage1, stage2, crisis

    init(systolic: Int, diastolic: Int) {
        if systolic > 180 || diastolic > 120 {
            self = .crisis
        } else if systolic >= 140 || diastolic >= 90 {
            self = .stage2
        } else if systolic >= 130 || diastolic >= 80 {
            self = .stage1
        } else if systolic >= 120 {
            self = .elevated
        } else if systolic < 90 || diastolic < 60 {
            self = .low
        } else {
            self = .normal
        }
    }

    var label: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .stage1: return "High Blood Pressure Stage 1"
        case .stage2: return "High Blood Pressure Stage 2"
        case .crisis: return "Very High"
        }
    }
}

// MARK: - Reading Checks

/// A problem with the numbers on the confirm screen.
/// `blocksSave` problems are physically implausible (almost certainly a misread);
/// the others are possible but worth a second look.
struct ReadingIssue: Identifiable, Equatable {
    let message: String
    let blocksSave: Bool
    var id: String { message }
}

enum ReadingChecks {

    static func bloodPressure(systolic: Int?, diastolic: Int?, pulse: Int?) -> [ReadingIssue] {
        var issues: [ReadingIssue] = []
        guard let systolic, let diastolic else { return issues }

        if !(50...300).contains(systolic) {
            issues.append(.init(message: "Systolic \(systolic) is outside the range a monitor can show (50–300). Check the number.", blocksSave: true))
        }
        if !(30...200).contains(diastolic) {
            issues.append(.init(message: "Diastolic \(diastolic) is outside the range a monitor can show (30–200). Check the number.", blocksSave: true))
        }
        if systolic <= diastolic {
            issues.append(.init(message: "Systolic (top number) should be higher than diastolic. They may be swapped.", blocksSave: true))
        }
        if let pulse, !(25...250).contains(pulse) {
            issues.append(.init(message: "Pulse \(pulse) looks wrong (expected 25–250 bpm). Check it or leave it empty.", blocksSave: true))
        }

        if issues.isEmpty, BPCategory(systolic: systolic, diastolic: diastolic) == .crisis {
            issues.append(.init(message: "This reading is very high. Rest a few minutes and measure again. If it stays this high, or you have chest pain, shortness of breath or trouble seeing or speaking, get medical help right away.", blocksSave: false))
        }
        return issues
    }

    static func weight(_ weight: Double?, unit: WeightUnit?) -> [ReadingIssue] {
        guard let weight, let unit else { return [] }
        let range: ClosedRange<Double> = unit == .kg ? 2...300 : 5...660
        if !range.contains(weight) {
            let low = Int(range.lowerBound), high = Int(range.upperBound)
            return [.init(message: "\(weight.formatted()) \(unit.rawValue) is outside \(low)–\(high) \(unit.rawValue). Check the number and the unit.", blocksSave: true)]
        }
        return []
    }
}
