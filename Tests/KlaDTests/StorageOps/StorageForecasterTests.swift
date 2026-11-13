// StorageForecasterTests.swift
import Foundation
import Testing
import KlaDModels
@testable import KlaDStorageOps

private let GB: UInt64 = 1 << 30
private let TOTAL: UInt64 = 1000 * GB

private let calendar = Calendar.current
private let now: Date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!

/// A sample `daysAgo` days before `now` (at `hour` o'clock) using `usedGB` of a 1000 GB volume.
private func sample(_ daysAgo: Int, _ usedGB: Double, hour: Int = 12, total: UInt64 = TOTAL) -> UsageSample {
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    let date = calendar.date(byAdding: .hour, value: hour, to: day)!
    return UsageSample(date: date, usedBytes: UInt64(usedGB * Double(GB)), totalBytes: total)
}

/// Daily samples for `days` days ending today: used(dayIndex) where dayIndex 0 is the oldest.
private func series(days: Int, used: (Int) -> Double) -> [UsageSample] {
    (0..<days).map { sample(days - 1 - $0, used($0)) }
}

@Suite("StorageForecaster")
struct StorageForecasterTests {
    private let forecaster = StorageForecaster()

    @Test func linearGrowthGivesExactDays() {
        // 500 GB + 10 GB/day for 30 days ⇒ 790 GB used today, 210 GB free ⇒ 21 days.
        let samples = series(days: 30) { 500 + 10 * Double($0) }
        let outcome = forecaster.forecast(samples: samples, now: now)
        #expect(outcome == .fillsIn(lowDays: 21, highDays: 21, bytesPerDay: Int64(10 * GB)), "\(outcome)")
    }

    @Test func flatUsageIsNotFillingUp() {
        let outcome = forecaster.forecast(samples: series(days: 20) { _ in 400 }, now: now)
        #expect(outcome == .notFillingUp(bytesPerDay: 0))
    }

    @Test func shrinkingUsageIsNotFillingUp() {
        let outcome = forecaster.forecast(samples: series(days: 20) { 600 - 2 * Double($0) }, now: now)
        #expect(outcome == .notFillingUp(bytesPerDay: -Int64(2 * GB)))
    }

    @Test func tooLittleDataIsInsufficient() {
        // Three days only.
        #expect(forecaster.forecast(samples: [sample(2, 500), sample(1, 501), sample(0, 502)], now: now)
                == .insufficientData(daysCovered: 2, distinctDays: 3))
        // Long span but only three distinct days.
        #expect(forecaster.forecast(samples: [sample(20, 500), sample(10, 510), sample(0, 520)], now: now)
                == .insufficientData(daysCovered: 20, distinctDays: 3))
        // Four distinct days but a span under a week.
        #expect(forecaster.forecast(samples: [sample(5, 500), sample(4, 501), sample(3, 502), sample(2, 503)], now: now)
                == .insufficientData(daysCovered: 3, distinctDays: 4))
        // Nothing at all.
        #expect(forecaster.forecast(samples: [], now: now) == .insufficientData(daysCovered: 0, distinctDays: 0))
        // Exactly 7 days over 4 distinct days is enough.
        let enough = forecaster.forecast(samples: [sample(7, 500), sample(5, 502), sample(2, 505), sample(0, 507)], now: now)
        if case .insufficientData = enough { Issue.record("7 days / 4 distinct days should be enough: \(enough)") }
    }

    @Test func onlyTheLastSamplePerDayCounts() {
        var samples = series(days: 20) { 500 + 5 * Double($0) }
        // Earlier, wildly different readings on the same days must be ignored.
        for daysAgo in 0..<20 { samples.append(sample(daysAgo, 900, hour: 3)) }
        var generator = SeededGenerator(seed: 42)
        let outcome = forecaster.forecast(samples: samples.shuffled(using: &generator), now: now)
        #expect(outcome == forecaster.forecast(samples: series(days: 20) { 500 + 5 * Double($0) }, now: now))
    }

    @Test func oneBigDownloadIsExcluded() {
        // +1 GB/day, plus a single 60 GB download on day 15 that stays on disk.
        let samples = series(days: 30) { Double(400 + $0) + ($0 >= 15 ? 60 : 0) }
        let outcome = forecaster.forecast(samples: samples, now: now)
        guard case let .fillsIn(low, high, perDay) = outcome else { Issue.record("expected fillsIn, got \(outcome)"); return }
        #expect(abs(Double(perDay) - Double(GB)) < 0.1 * Double(GB), "slope \(Double(perDay) / Double(GB)) GB/day should stay near 1")
        #expect(low <= high)
        // Free = 1000 − (429 + 60) = 511 GB at ~1 GB/day ⇒ ~500 days, certainly not the ~8 days the jump would imply.
        #expect(low > 400)

        // The step itself is what gets removed from the later points.
        let adjusted = StorageForecaster.removingJumps(samples.enumerated().map {
            StorageForecaster.DailyPoint(dayIndex: $0.offset, used: Double($0.element.usedBytes), total: TOTAL, usedBytes: $0.element.usedBytes)
        })
        #expect(adjusted.last! < Double(430 * GB), "the 60 GB step must be removed from later points")
    }

    @Test func steadyFastGrowthIsNotMistakenForAJump() {
        let outcome = forecaster.forecast(samples: series(days: 25) { 100 + 6 * Double($0) }, now: now)
        #expect(outcome == .fillsIn(lowDays: 126, highDays: 126, bytesPerDay: Int64(6 * GB)), "\(outcome)")
    }

    @Test func jumpsSmallerThanFiveGBAreKept() {
        // Flat at 400 GB with one +4 GB step: |Δ| > 3× median (0) but not > 5 GB ⇒ the step stays in the data.
        // (Had it been removed, the series would be perfectly flat ⇒ `.notFillingUp(0)`.)
        let outcome = forecaster.forecast(samples: series(days: 20) { $0 >= 10 ? 404 : 400 }, now: now)
        guard case let .moreThanTwoYears(perDay) = outcome else { Issue.record("expected a small positive slope, got \(outcome)"); return }
        #expect(perDay > 0)
    }

    @Test func noisyGrowthKeepsRangeOrdering() {
        for seed in 1...25 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let samples = series(days: 40) { day in
                500 + 5 * Double(day) + Double.random(in: -4...4, using: &generator)
            }
            let outcome = forecaster.forecast(samples: samples, now: now)
            switch outcome {
            case let .fillsIn(low, high, perDay):
                #expect(low >= 0 && low <= high, "seed \(seed): \(outcome)")
                #expect(high <= 730, "seed \(seed): \(outcome)")
                #expect(perDay > 4 * Int64(GB) && perDay < 6 * Int64(GB), "seed \(seed): \(outcome)")
            case .moreThanTwoYears, .notFillingUp, .insufficientData:
                Issue.record("seed \(seed): unexpected \(outcome)")
            }
        }
    }

    @Test func slowGrowthBeyondTwoYears() {
        // 0.1 GB/day with ~500 GB free ⇒ ~13 years.
        let outcome = forecaster.forecast(samples: series(days: 30) { 450 + 0.1 * Double($0) }, now: now)
        guard case let .moreThanTwoYears(perDay) = outcome else { Issue.record("expected moreThanTwoYears, got \(outcome)"); return }
        #expect(perDay > 0)
    }

    @Test func highEstimateIsCappedWhenTheLowerQuartileIsFlat() {
        // 20 flat days then 10 days of +4 GB (below the 5 GB jump threshold): ≥ 25 % of the pairwise slopes are zero.
        let samples = series(days: 30) { $0 < 20 ? 500 : 500 + 4 * Double($0 - 19) }
        let outcome = forecaster.forecast(samples: samples, now: now)
        guard case let .fillsIn(low, high, perDay) = outcome else { Issue.record("expected fillsIn, got \(outcome)"); return }
        #expect(high == 730, "an unknown upper bound is capped, never extrapolated: \(outcome)")
        #expect(low <= high && low > 0)
        #expect(perDay > 0)
    }

    @Test func oldHistoryOutsideSixtyDaysIsIgnored() {
        let recent = series(days: 20) { 500 + 3 * Double($0) }
        var withAncient = recent
        var generator = SeededGenerator(seed: 7)
        for daysAgo in 70...100 { withAncient.append(sample(daysAgo, Double.random(in: 100...900, using: &generator))) }
        #expect(forecaster.forecast(samples: withAncient, now: now) == forecaster.forecast(samples: recent, now: now))
    }

    @Test func futureSamplesAreIgnoredAndResultIsDeterministic() {
        let samples = series(days: 15) { 300 + 4 * Double($0) }
        let future = UsageSample(date: now.addingTimeInterval(5 * 86_400), usedBytes: 999 * GB, totalBytes: TOTAL)
        let a = forecaster.forecast(samples: samples + [future], now: now)
        let b = forecaster.forecast(samples: samples, now: now)
        #expect(a == b)
        #expect(forecaster.forecast(samples: samples, now: now) == b)
    }

    @Test func percentileInterpolates() {
        #expect(StorageForecaster.percentile([], 0.5) == 0)
        #expect(StorageForecaster.percentile([7], 0.9) == 7)
        #expect(StorageForecaster.percentile([1, 2, 3, 4, 5], 0.5) == 3)
        #expect(StorageForecaster.percentile([1, 2, 3, 4, 5], 0.25) == 2)
        #expect(StorageForecaster.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(StorageForecaster.percentile([10, 20], 0.75) == 17.5)
    }
}

// MARK: - Deterministic randomness for the tests

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {   // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
