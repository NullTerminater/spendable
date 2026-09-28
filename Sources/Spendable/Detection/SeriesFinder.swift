import Foundation

/// One bank row as detection sees it: already sign-corrected, so a debit is always negative.
struct DetectionRow: Equatable, Sendable {
    var id: Int64
    /// Negative for money leaving the account, after `amounts_reversed` has been applied.
    var amountCents: Int64
    /// The UTC calendar day of the row's `detect_at` (decision 8). Nil rows never reach the finder.
    var day: CalendarDay
    /// The UTC day it posted, when it has posted.
    var postedDay: CalendarDay?
    /// Whether `day` came from a plausible transaction date rather than the posting date.
    var dayIsTransactionDate: Bool
    var pending: Bool

    var isDebit: Bool { amountCents < 0 }
    var magnitude: Int64 { amountCents < 0 ? -amountCents : amountCents }
}

/// A run of charges that repeat, as found in one merchant key's bounded history.
struct FoundTrack: Equatable, Sendable {
    enum Confidence: Equatable, Sendable {
        /// Two charges: shown as "these might be bills", never counted.
        case suggested
        /// Three or more, with nothing ambiguous about them: counted, visibly badged.
        case confirmed
    }

    var memberIds: [Int64]
    var memberDays: [CalendarDay]
    var cadence: Cadence
    var currentAmountCents: Int64
    var firstAmountCents: Int64
    /// The last price step: from what, and on which day.
    var priceChange: (fromCents: Int64, on: CalendarDay)?
    var confidence: Confidence
    var anchor: CalendarDay

    var lastDay: CalendarDay { memberDays.last ?? anchor }

    static func == (lhs: FoundTrack, rhs: FoundTrack) -> Bool {
        lhs.memberIds == rhs.memberIds && lhs.cadence == rhs.cadence
            && lhs.currentAmountCents == rhs.currentAmountCents && lhs.firstAmountCents == rhs.firstAmountCents
            && lhs.priceChange?.fromCents == rhs.priceChange?.fromCents && lhs.priceChange?.on == rhs.priceChange?.on
            && lhs.confidence == rhs.confidence && lhs.anchor == rhs.anchor
    }
}

/// The pure part of detection (`docs/reviews/milestone-5-review.md`, decision 9, steps 3-6).
///
/// No database, no clock, no calendar but UTC. Given every live row of one merchant key on one
/// account, in date order, it answers which runs of charges repeat. Each key is always recomputed
/// from its whole bounded history, so running it once over everything and running it again after
/// each small change give the same answer.
enum SeriesFinder {
    /// More rows than this in the look-back makes a key too dense to read (decision 9).
    static let maxRowsPerKey = 400
    /// How far back a key's history is read: thirteen months of history plus the widest tolerance.
    static let lookBackDays = 430

    static let utc = CalendarDay.utc

    /// The day windows a gap must fall in for each cadence.
    static func window(_ cadence: Cadence) -> ClosedRange<Int> {
        switch cadence {
        case .weekly: 5...9
        case .biweekly: 12...16
        case .monthly: 26...35
        case .quarterly: 80...100
        case .annual: 340...395
        }
    }

    /// How far from its due day a charge may land and still pay that occurrence (decision 14).
    /// Never close to half an interval, so a late charge cannot pay the next one instead.
    static func tolerance(_ cadence: Cadence) -> Int {
        switch cadence {
        case .weekly: 2
        case .biweekly: 5
        case .monthly: 5
        case .quarterly: 10
        case .annual: 20
        }
    }

    struct Result: Equatable, Sendable {
        var tracks: [FoundTrack]
        /// Debit ids a refund cancelled out, one-to-one.
        var refunded: [Int64]
    }

    static func find(_ rows: [DetectionRow]) -> Result {
        let settled = rows.filter { !$0.pending }
        let refunded = pairRefunds(settled)
        let debits = settled.filter { $0.isDebit && !refunded.contains($0.id) }
            .sorted { ($0.day, $0.id) < ($1.day, $1.id) }

        var tracks: [FoundTrack] = []
        for amountTrack in buildAmountTracks(debits) {
            tracks.append(contentsOf: classify(amountTrack))
        }
        tracks.sort { ($0.memberDays.first ?? $0.anchor, $0.memberIds.first ?? 0) < ($1.memberDays.first ?? $1.anchor, $1.memberIds.first ?? 0) }
        return Result(tracks: tracks, refunded: refunded.sorted())
    }

    // MARK: Refunds (decision 17)

    /// A credit cancels exactly one debit: same magnitude, 0-30 days after it, and the only debit
    /// that qualifies. Ambiguity pairs nothing, so a credit can never erase two charges.
    static func pairRefunds(_ settled: [DetectionRow]) -> Set<Int64> {
        let debits = settled.filter(\.isDebit)
        let credits = settled.filter { !$0.isDebit && $0.amountCents > 0 }.sorted { ($0.day, $0.id) < ($1.day, $1.id) }
        var paired: Set<Int64> = []
        for credit in credits {
            let candidates = debits.filter { debit in
                guard !paired.contains(debit.id), debit.magnitude == credit.magnitude else { return false }
                let apart = debit.day.days(to: credit.day, in: utc)
                return apart >= 0 && apart <= 30
            }
            if candidates.count == 1 { paired.insert(candidates[0].id) }
        }
        return paired
    }

    // MARK: Amount tracks (decision 9, step 4)

    struct AmountTrack {
        var members: [DetectionRow] = []
        var current: Int64 = 0
        var first: Int64 = 0
        var priceChange: (fromCents: Int64, on: CalendarDay)?
        /// A row that could have joined this track as easily as another joined neither, so nothing
        /// here may become confident.
        var capped = false

        var lastDay: CalendarDay? { members.last?.day }

        /// Lower middle of the gaps so far, in whole days.
        var medianGap: Int? {
            guard members.count >= 2 else { return nil }
            let gaps = zip(members, members.dropFirst()).map { $0.day.days(to: $1.day, in: SeriesFinder.utc) }.sorted()
            return gaps[(gaps.count - 1) / 2]
        }

        func withinBand(_ amount: Int64) -> Bool {
            // |a - c| / c <= 5%, in integers.
            let difference = amount > current ? amount - current : current - amount
            return difference * 100 <= 5 * current
        }

        func distanceToExpected(_ day: CalendarDay) -> Int {
            guard let last = lastDay else { return 0 }
            guard let gap = medianGap else { return abs(last.days(to: day, in: SeriesFinder.utc)) }
            let expected = last.adding(days: gap, in: SeriesFinder.utc)
            return abs(expected.days(to: day, in: SeriesFinder.utc))
        }
    }

    static func buildAmountTracks(_ debits: [DetectionRow]) -> [AmountTrack] {
        var tracks: [AmountTrack] = []
        for row in debits {
            let amount = row.magnitude
            let inBand = tracks.indices.filter { tracks[$0].withinBand(amount) }

            if inBand.count == 1 {
                append(row, to: &tracks[inBand[0]])
                continue
            }
            if inBand.count > 1 {
                let distances = inBand.map { tracks[$0].distanceToExpected(row.day) }
                let best = distances.min() ?? 0
                let nearest = inBand.enumerated().filter { distances[$0.offset] == best }.map(\.element)
                if nearest.count == 1 {
                    append(row, to: &tracks[nearest[0]])
                } else {
                    // Joins nothing, and nothing it could have joined may count on it.
                    for index in inBand { tracks[index].capped = true }
                }
                continue
            }

            // A price change: one sequential step within -25%..+50%, at least three quarters of an
            // interval after the last charge, on a track with a rhythm already.
            let steps = tracks.indices.filter { index in
                let track = tracks[index]
                guard track.members.count >= 2, let last = track.lastDay, let gap = track.medianGap else { return false }
                let c = track.current
                guard 75 * c <= 100 * amount, 100 * amount <= 150 * c else { return false }
                return 4 * last.days(to: row.day, in: utc) >= 3 * gap
            }
            if steps.count == 1 {
                let index = steps[0]
                tracks[index].priceChange = (fromCents: tracks[index].current, on: row.day)
                tracks[index].current = amount
                tracks[index].members.append(row)
                continue
            }

            var track = AmountTrack()
            track.first = amount
            track.current = amount
            track.members = [row]
            tracks.append(track)
        }
        return tracks
    }

    /// The band follows the latest price, so a charge that creeps up a cent at a time stays one bill.
    private static func append(_ row: DetectionRow, to track: inout AmountTrack) {
        track.members.append(row)
        track.current = row.magnitude
    }

    // MARK: Cadence (decision 9, step 5)

    struct CadenceFit: Equatable {
        var cadence: Cadence
        var usedSkip: Bool
    }

    /// Which cadence the gaps between these days fit, if exactly one does.
    static func fitCadence(_ days: [CalendarDay]) -> CadenceFit? {
        guard days.count >= 2 else { return nil }
        let gaps = zip(days, days.dropFirst()).map { $0.days(to: $1, in: utc) }

        // Without the skip allowance first. The windows do not overlap, so at most one cadence can
        // contain the median, and the skip is never what chooses between two.
        let plain = Cadence.allCases.filter { fits(gaps, $0, allowSkip: false) }
        if plain.count == 1 { return CadenceFit(cadence: plain[0], usedSkip: false) }
        if !plain.isEmpty { return nil }
        let skipped = Cadence.allCases.filter { fits(gaps, $0, allowSkip: true) }
        if skipped.count == 1 { return CadenceFit(cadence: skipped[0], usedSkip: true) }
        return nil
    }

    static func fits(_ gaps: [Int], _ cadence: Cadence, allowSkip: Bool) -> Bool {
        let window = window(cadence)
        var adjusted: [Int] = []
        var fitting = 0
        var skipUsed = false
        for gap in gaps {
            if window.contains(gap) {
                fitting += 1
                adjusted.append(gap)
            } else if allowSkip, gaps.count >= 3, !skipUsed,
                      (2 * window.lowerBound...2 * window.upperBound).contains(gap) {
                // One doubled gap is one missed charge.
                skipUsed = true
                fitting += 1
                adjusted.append((gap + 1) / 2)
            } else {
                adjusted.append(gap)
            }
        }
        if allowSkip && !skipUsed { return false }
        // At least 80%, which for two to four gaps means all of them.
        guard 5 * fitting >= 4 * gaps.count else { return false }
        let sorted = adjusted.sorted()
        return window.contains(sorted[(sorted.count - 1) / 2])
    }

    /// Turns one amount track into zero, one or two found tracks.
    static func classify(_ track: AmountTrack) -> [FoundTrack] {
        let rows = track.members
        guard rows.count >= 2 else { return [] }

        // One measuring basis per track (decision 8): if any member lacks a trustworthy transaction
        // date, every gap is measured between posting dates instead.
        let days: [CalendarDay] = rows.allSatisfy(\.dayIsTransactionDate)
            ? rows.map(\.day)
            : rows.map { $0.postedDay ?? $0.day }

        guard let fit = fitCadence(days) else { return [] }
        var capped = track.capped

        // Two monthly charges on different days of the month look biweekly. A true biweekly charge
        // drifts about two days a month against the calendar; two monthly ones do not.
        if fit.cadence == .weekly || fit.cadence == .biweekly {
            let clusters = dayOfMonthClusters(rows, days: days)
            if clusters.count <= 2 {
                let split = clusters.map { cluster in (cluster, fitCadence(cluster.map { days[$0] })) }
                if clusters.count == 2, split.allSatisfy({ $0.0.count >= 2 && $0.1?.cadence == .monthly }) {
                    return split.map { cluster, fit in
                        found(rows: cluster.map { rows[$0] }, days: cluster.map { days[$0] },
                              cadence: fit?.cadence ?? .monthly, track: track, capped: capped)
                    }
                }
                // Both readings still possible: not enough history to be sure which.
                if rows.count < 6 { capped = true }
            }
        }
        return [found(rows: rows, days: days, cadence: fit.cadence, track: track, capped: capped)]
    }

    /// Indices of `rows` grouped by day of the month, two days apart or closer.
    private static func dayOfMonthClusters(_ rows: [DetectionRow], days: [CalendarDay]) -> [[Int]] {
        let order = days.indices.sorted { (days[$0].day, $0) < (days[$1].day, $1) }
        var clusters: [[Int]] = []
        var lastDay = -100
        for index in order {
            let day = days[index].day
            if day - lastDay <= 2, !clusters.isEmpty {
                clusters[clusters.count - 1].append(index)
            } else {
                clusters.append([index])
            }
            lastDay = day
        }
        return clusters.map { $0.sorted() }
    }

    private static func found(
        rows: [DetectionRow], days: [CalendarDay], cadence: Cadence, track: AmountTrack, capped: Bool
    ) -> FoundTrack {
        let confidence: FoundTrack.Confidence = rows.count >= 3 && !capped ? .confirmed : .suggested
        // The price step belongs to this run only if the run has charges on both sides of it.
        let change = track.priceChange.flatMap { change in
            days.contains(where: { $0 >= change.on }) && days.contains(where: { $0 < change.on }) ? change : nil
        }
        return FoundTrack(
            memberIds: rows.map(\.id), memberDays: days, cadence: cadence,
            currentAmountCents: rows.last?.magnitude ?? track.current,
            firstAmountCents: rows.first?.magnitude ?? track.first,
            priceChange: change, confidence: confidence, anchor: anchor(days: days, cadence: cadence))
    }

    /// The day occurrences are measured from (decision 14). For a monthly-style bill that has ever
    /// landed on the last day of a month, the latest day of the month it has used, so a bill on the
    /// 31st that was first seen on February 28th is not anchored to the 28th forever.
    static func anchor(days: [CalendarDay], cadence: Cadence) -> CalendarDay {
        guard let last = days.last else { return CalendarDay(year: 1970, month: 1, day: 1) }
        guard cadence.stepMonths != nil else { return last }
        let endsOfMonth = days.filter { $0 == $0.endOfMonth(in: utc) }
        guard !endsOfMonth.isEmpty else { return last }
        let latestDay = days.map(\.day).max() ?? last.day
        return days.last(where: { $0.day == latestDay }) ?? last
    }

    // MARK: Occurrences

    /// The occurrence `index` steps from `anchor`, measured from the anchor every time.
    static func occurrence(_ index: Int, from anchor: CalendarDay, cadence: Cadence) -> CalendarDay {
        if let days = cadence.stepDays { return anchor.adding(days: days * index, in: utc) }
        return anchor.adding(months: (cadence.stepMonths ?? 1) * index, in: utc)
    }

    /// The occurrence a charge on `day` pays, if it lands within tolerance of exactly one.
    static func occurrencePaid(by day: CalendarDay, anchor: CalendarDay, cadence: Cadence) -> CalendarDay? {
        let tolerance = tolerance(cadence)
        // Estimate the index, then look at its neighbours.
        let estimate: Int
        if let step = cadence.stepDays {
            estimate = anchor.days(to: day, in: utc) / step
        } else {
            let months = (day.year - anchor.year) * 12 + (day.month - anchor.month)
            estimate = months / (cadence.stepMonths ?? 1)
        }
        let candidates = (estimate - 1...estimate + 1).map { occurrence($0, from: anchor, cadence: cadence) }
            .filter { abs($0.days(to: day, in: utc)) <= tolerance }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
