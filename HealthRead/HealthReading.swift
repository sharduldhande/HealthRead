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
}
