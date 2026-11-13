// StorageForecaster.swift — KlaDStorageOps
//
// An honest "when will this disk fill up?" estimate. Never a fake exact date: the
// answer is a *range* of days (or "not filling up" / "more than two years" /
// "not enough history"), derived from a robust trend over the last 60 days:
//
//   1. keep the last sample of every calendar day within the last 60 days;
//   2. need a span of ≥ 7 days over ≥ 4 distinct days, else `.insufficientData`;
//   3. exclude sudden one-day jumps (|Δ| > 3× the median absolute daily change AND
//      > 5 GB — one big download is not a trend). Excluding a jump means removing
//      its step from every later point, so the rest of the series stays comparable;
//   4. Theil–Sen slope: the median of every pairwise slope (bytes/day). The range
//      comes from the 25th / 75th percentile slopes;
//   5. slope ≤ 0 (or the 75th percentile ≤ 0) ⇒ `.notFillingUp`; otherwise
//      days = free ÷ slope, the low estimate from the steeper slope. A low estimate
//      beyond 730 days ⇒ `.moreThanTwoYears`; the high estimate is capped at 730.
//
// Pure and deterministic: the result depends only on `samples`, `now` and the
// current calendar.

import Foundation
import KlaDModels

public struct StorageForecaster: StorageForecasting {
    public init() {}

    static let windowDays = 60
    static let minimumSpanDays = 7
    static let minimumDistinctDays = 4
    static let maximumDays = 730
    static let jumpMultiplier = 3.0
    static let jumpMinimumBytes = 5.0 * 1_073_741_824

    /// One calendar day's last sample.
    struct DailyPoint {
        var dayIndex: Int          // days since the reference day
        var used: Double
        var total: UInt64
        var usedBytes: UInt64
    }

    public func forecast(samples: [UsageSample], now: Date) -> ForecastOutcome {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -Self.windowDays, to: today) else {
            return .insufficientData(daysCovered: 0, distinctDays: 0)
        }

        // 1. Last sample per calendar day inside the window (ignore the future).
        var lastPerDay: [Date: UsageSample] = [:]
        for sample in samples where sample.date >= windowStart && sample.date <= now {
            let day = calendar.startOfDay(for: sample.date)
            if let existing = lastPerDay[day], existing.date > sample.date { continue }
            lastPerDay[day] = sample
        }
        let days = lastPerDay.keys.sorted()
        var points: [DailyPoint] = []
        for day in days {
            guard let sample = lastPerDay[day] else { continue }
            let index = calendar.dateComponents([.day], from: windowStart, to: day).day ?? 0
            points.append(DailyPoint(dayIndex: index, used: Double(sample.usedBytes), total: sample.totalBytes, usedBytes: sample.usedBytes))
        }

        // 2. Enough history?
        guard let first = points.first, let last = points.last else {
            return .insufficientData(daysCovered: 0, distinctDays: 0)
        }
        let span = last.dayIndex - first.dayIndex
        guard span >= Self.minimumSpanDays, points.count >= Self.minimumDistinctDays else {
            return .insufficientData(daysCovered: span, distinctDays: points.count)
        }

        // 3. Remove sudden one-day jumps.
        let adjusted = Self.removingJumps(points)

        // 4. Theil–Sen slopes (bytes/day).
        var slopes: [Double] = []
        slopes.reserveCapacity(adjusted.count * (adjusted.count - 1) / 2)
        for i in 0..<adjusted.count {
            for j in (i + 1)..<adjusted.count {
                let days = Double(points[j].dayIndex - points[i].dayIndex)
                guard days > 0 else { continue }
                slopes.append((adjusted[j] - adjusted[i]) / days)
            }
        }
        guard !slopes.isEmpty else { return .insufficientData(daysCovered: span, distinctDays: points.count) }
        slopes.sort()
        let median = Self.percentile(slopes, 0.5)
        let lowSlope = Self.percentile(slopes, 0.25)
        let highSlope = Self.percentile(slopes, 0.75)

        let bytesPerDay = Self.clampedInt64(median)
        if median <= 0 || highSlope <= 0 {
            return .notFillingUp(bytesPerDay: bytesPerDay)
        }

        // 5. Days until full. Free space as of the latest sample.
        let free = Double(last.total > last.usedBytes ? last.total - last.usedBytes : 0)
        let lowDaysExact = free / highSlope                      // steeper slope ⇒ sooner
        if lowDaysExact > Double(Self.maximumDays) {
            return .moreThanTwoYears(bytesPerDay: bytesPerDay)
        }
        let highDaysExact = lowSlope > 0 ? free / lowSlope : Double(Self.maximumDays)
        let lowDays = Int(lowDaysExact.rounded(.down))
        let highDays = min(Self.maximumDays, max(lowDays, Int(min(highDaysExact, Double(Self.maximumDays)).rounded(.up))))
        return .fillsIn(lowDays: lowDays, highDays: highDays, bytesPerDay: bytesPerDay)
    }

    // MARK: Pieces (internal for tests)

    /// Used-bytes series with every sudden jump's step removed from all later points.
    static func removingJumps(_ points: [DailyPoint]) -> [Double] {
        guard points.count > 1 else { return points.map(\.used) }
        // Per-day rate of change between consecutive samples (gaps are spread out).
        var steps: [(delta: Double, perDay: Double)] = []
        for i in 1..<points.count {
            let gap = Double(max(1, points[i].dayIndex - points[i - 1].dayIndex))
            let delta = points[i].used - points[i - 1].used
            steps.append((delta, delta / gap))
        }
        let medianAbs = percentile(steps.map { abs($0.perDay) }.sorted(), 0.5)
        var offset = 0.0
        var result = [points[0].used]
        for (index, step) in steps.enumerated() {
            let isJump = abs(step.perDay) > jumpMultiplier * medianAbs && abs(step.delta) > jumpMinimumBytes
            if isJump { offset += step.delta }
            result.append(points[index + 1].used - offset)
        }
        return result
    }

    /// Linear-interpolated percentile of an ascending array (`fraction` in 0…1).
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let weight = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }

    private static func clampedInt64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        return Int64(max(-9.0e18, min(9.0e18, value.rounded())))
    }
}
