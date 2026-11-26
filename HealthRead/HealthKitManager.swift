import Foundation
import HealthKit

/// Manages health data storage.
/// Uses HealthKit when available (paid developer account + real device).
/// Falls back to local JSON storage otherwise.
@Observable
class HealthKitManager {

    private let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private(set) var isAuthorized = false
    private(set) var isHealthKitAvailable = false

    // Local storage fallback
    private var localBPReadings: [BloodPressureReading] = []
    private var localWeightReadings: [WeightReading] = []
    private let storageURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("health_readings.json")
    }()

    init() {
        loadLocalReadings()
    }

    /// The HealthKit types we need write access to
    private var typesToShare: Set<HKSampleType> {
        Set([
            HKQuantityType(.bloodPressureSystolic),
            HKQuantityType(.bloodPressureDiastolic),
            HKQuantityType(.heartRate),
            HKQuantityType(.bodyMass),
        ])
    }

    /// Request HealthKit authorization. Falls back gracefully if unavailable.
    func requestAuthorization() async -> Bool {
        guard let healthStore else {
            print("HealthKit not available — using local storage")
            isHealthKitAvailable = false
            return false
        }

        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToShare)
            isAuthorized = true
            isHealthKitAvailable = true
            return true
        } catch {
            print("HealthKit authorization failed: \(error) — using local storage")
            isHealthKitAvailable = false
            return false
        }
    }

    // MARK: - Save

    /// Where a saved reading ended up, so the UI never claims Apple Health when it wasn't used.
    enum SaveDestination {
        case appleHealth
        case thisDeviceOnly
    }

    /// Decides from HealthKit's own record of the person's answer, not from whether an
    /// earlier request returned: a request that never came back used to hang every save.
    private func healthStoreForWriting(_ type: HKQuantityType) async -> HKHealthStore? {
        guard let healthStore else { return nil }
        switch healthStore.authorizationStatus(for: type) {
        case .sharingAuthorized, .sharingDenied:
            // Denied still returns the store: the write then fails with a clear
            // "Health access is off" error instead of a silent app-only save.
            isHealthKitAvailable = true
            return healthStore
        case .notDetermined:
            return await requestAuthorization() ? healthStore : nil
        @unknown default:
            return await requestAuthorization() ? healthStore : nil
        }
    }

    /// Save a blood pressure reading. Throws if Apple Health refuses the write
    /// (for example, access was turned off), so the user sees an error instead of a false success.
    @discardableResult
    func saveBloodPressure(_ reading: BloodPressureReading) async throws -> SaveDestination {
        var destination = SaveDestination.thisDeviceOnly
        if let store = await healthStoreForWriting(HKQuantityType(.bloodPressureSystolic)) {
            try await saveBloodPressureToHealthKit(reading, store: store)
            destination = .appleHealth
        }
        // Always save locally too (as backup / for history view)
        localBPReadings.insert(reading, at: 0)
        saveLocalReadings()
        return destination
    }

    /// Save a weight reading. See `saveBloodPressure` for the error behavior.
    @discardableResult
    func saveWeight(_ reading: WeightReading) async throws -> SaveDestination {
        var destination = SaveDestination.thisDeviceOnly
        if let store = await healthStoreForWriting(HKQuantityType(.bodyMass)) {
            try await saveWeightToHealthKit(reading, store: store)
            destination = .appleHealth
        }
        localWeightReadings.insert(reading, at: 0)
        saveLocalReadings()
        return destination
    }

    // MARK: - Delete

    /// Delete a blood pressure reading (HealthKit + local)
    func deleteBloodPressure(_ reading: BloodPressureReading) async throws {
        if isHealthKitAvailable, let healthStore {
            try await deleteBPFromHealthKit(reading, store: healthStore)
        }
        localBPReadings.removeAll { $0.id == reading.id }
        saveLocalReadings()
    }

    /// Delete a weight reading (HealthKit + local)
    func deleteWeight(_ reading: WeightReading) async throws {
        if isHealthKitAvailable, let healthStore {
            try await deleteWeightFromHealthKit(reading, store: healthStore)
        }
        localWeightReadings.removeAll { $0.id == reading.id }
        saveLocalReadings()
    }

    // MARK: - Fetch

    /// Fetch recent blood pressure readings
    func fetchRecentBloodPressure(limit: Int = 20) async -> [BloodPressureReading] {
        if isHealthKitAvailable, let healthStore {
            let hkReadings = await fetchBPFromHealthKit(limit: limit, store: healthStore)
            if !hkReadings.isEmpty { return hkReadings }
        }
        return Array(localBPReadings.prefix(limit))
    }

    /// Fetch recent weight readings
    func fetchRecentWeight(limit: Int = 20) async -> [WeightReading] {
        if isHealthKitAvailable, let healthStore {
            let hkReadings = await fetchWeightFromHealthKit(limit: limit, store: healthStore)
            if !hkReadings.isEmpty { return hkReadings }
        }
        return Array(localWeightReadings.prefix(limit))
    }

    // MARK: - HealthKit Write (Private)

    private func saveBloodPressureToHealthKit(_ reading: BloodPressureReading, store: HKHealthStore) async throws {
        let mmHg = HKUnit.millimeterOfMercury()

        let systolicSample = HKQuantitySample(
            type: HKQuantityType(.bloodPressureSystolic),
            quantity: HKQuantity(unit: mmHg, doubleValue: Double(reading.systolic)),
            start: reading.timestamp,
            end: reading.timestamp
        )
        let diastolicSample = HKQuantitySample(
            type: HKQuantityType(.bloodPressureDiastolic),
            quantity: HKQuantity(unit: mmHg, doubleValue: Double(reading.diastolic)),
            start: reading.timestamp,
            end: reading.timestamp
        )

        let correlation = HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: reading.timestamp,
            end: reading.timestamp,
            objects: Set([systolicSample, diastolicSample])
        )

        try await store.save(correlation)

        if let pulse = reading.pulse {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let heartRateSample = HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(unit: bpm, doubleValue: Double(pulse)),
                start: reading.timestamp,
                end: reading.timestamp
            )
            try await store.save(heartRateSample)
        }
    }

    private func saveWeightToHealthKit(_ reading: WeightReading, store: HKHealthStore) async throws {
        let kg = HKUnit.gramUnit(with: .kilo)
        let sample = HKQuantitySample(
            type: HKQuantityType(.bodyMass),
            quantity: HKQuantity(unit: kg, doubleValue: reading.weightInKg),
            start: reading.timestamp,
            end: reading.timestamp
        )
        try await store.save(sample)
    }

    // MARK: - HealthKit Read (Private)

    private func fetchBPFromHealthKit(limit: Int, store: HKHealthStore) async -> [BloodPressureReading] {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCorrelationType(.bloodPressure),
                predicate: nil,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let correlations = samples as? [HKCorrelation] else {
                    continuation.resume(returning: [])
                    return
                }

                let readings: [BloodPressureReading] = correlations.compactMap { correlation in
                    guard let sys = (correlation.objects(for: HKQuantityType(.bloodPressureSystolic)).first as? HKQuantitySample)?
                            .quantity.doubleValue(for: .millimeterOfMercury()),
                          let dia = (correlation.objects(for: HKQuantityType(.bloodPressureDiastolic)).first as? HKQuantitySample)?
                            .quantity.doubleValue(for: .millimeterOfMercury())
                    else { return nil }

                    return BloodPressureReading(systolic: Int(sys), diastolic: Int(dia), pulse: nil, timestamp: correlation.startDate)
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }

    private func fetchWeightFromHealthKit(limit: Int, store: HKHealthStore) async -> [WeightReading] {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.bodyMass),
                predicate: nil,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let quantitySamples = samples as? [HKQuantitySample] else {
                    continuation.resume(returning: [])
                    return
                }

                let readings = quantitySamples.map { sample in
                    let kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                    return WeightReading(weight: kg * 2.20462, unit: .lbs, timestamp: sample.startDate)
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }

    // MARK: - HealthKit Delete (Private)

    private func deleteBPFromHealthKit(_ reading: BloodPressureReading, store: HKHealthStore) async throws {
        let predicate = HKQuery.predicateForSamples(
            withStart: reading.timestamp,
            end: reading.timestamp.addingTimeInterval(1),
            options: .strictStartDate
        )

        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: HKCorrelationType(.bloodPressure),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results ?? []) }
            }
            store.execute(query)
        }

        for sample in samples {
            try await store.delete(sample)
        }
    }

    private func deleteWeightFromHealthKit(_ reading: WeightReading, store: HKHealthStore) async throws {
        let predicate = HKQuery.predicateForSamples(
            withStart: reading.timestamp,
            end: reading.timestamp.addingTimeInterval(1),
            options: .strictStartDate
        )

        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.bodyMass),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: results ?? []) }
            }
            store.execute(query)
        }

        for sample in samples {
            try await store.delete(sample)
        }
    }

    // MARK: - Local JSON Storage

    private struct LocalStorage: Codable {
        var bpReadings: [CodableBP]
        var weightReadings: [CodableWeight]
    }

    private struct CodableBP: Codable {
        let id: UUID
        let systolic: Int
        let diastolic: Int
        let pulse: Int?
        let timestamp: Date

        init(id: UUID = UUID(), systolic: Int, diastolic: Int, pulse: Int?, timestamp: Date) {
            self.id = id
            self.systolic = systolic
            self.diastolic = diastolic
            self.pulse = pulse
            self.timestamp = timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            self.systolic = try container.decode(Int.self, forKey: .systolic)
            self.diastolic = try container.decode(Int.self, forKey: .diastolic)
            self.pulse = try container.decodeIfPresent(Int.self, forKey: .pulse)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        }
    }

    private struct CodableWeight: Codable {
        let id: UUID
        let weight: Double
        let unit: String
        let timestamp: Date

        init(id: UUID = UUID(), weight: Double, unit: String, timestamp: Date) {
            self.id = id
            self.weight = weight
            self.unit = unit
            self.timestamp = timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
            self.weight = try container.decode(Double.self, forKey: .weight)
            self.unit = try container.decode(String.self, forKey: .unit)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        }
    }

    private func loadLocalReadings() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let storage = try JSONDecoder().decode(LocalStorage.self, from: data)
            localBPReadings = storage.bpReadings.map {
                BloodPressureReading(systolic: $0.systolic, diastolic: $0.diastolic, pulse: $0.pulse, timestamp: $0.timestamp, id: $0.id)
            }
            localWeightReadings = storage.weightReadings.map {
                WeightReading(weight: $0.weight, unit: WeightUnit(rawValue: $0.unit) ?? .lbs, timestamp: $0.timestamp, id: $0.id)
            }
        } catch {
            print("Failed to load local readings: \(error)")
        }
    }

    private func saveLocalReadings() {
        let storage = LocalStorage(
            bpReadings: localBPReadings.map { CodableBP(id: $0.id, systolic: $0.systolic, diastolic: $0.diastolic, pulse: $0.pulse, timestamp: $0.timestamp) },
            weightReadings: localWeightReadings.map { CodableWeight(id: $0.id, weight: $0.weight, unit: $0.unit.rawValue, timestamp: $0.timestamp) }
        )
        do {
            let data = try JSONEncoder().encode(storage)
            try data.write(to: storageURL)
        } catch {
            print("Failed to save local readings: \(error)")
        }
    }
}
