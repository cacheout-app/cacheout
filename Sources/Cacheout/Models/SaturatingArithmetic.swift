import Foundation

/// Saturating `Int64` addition — THE aggregation operator for byte totals
/// that cross validated-outcome boundaries (PR #455 round 8).
///
/// The runtime validator bounds every SINGLE outcome: per-item component
/// pairs AND the outcome-wide `allocatedBytes` sum are proven representable
/// before anything is published (`SpaceScannerRuntime.validatedOutcome`,
/// check (d)). But totals that add ACROSS scanners — the GUI's frozen
/// scopes (`CacheoutViewModel.aggregateBytes`), the CLI's clean-plan totals
/// (`cleanPlanTotals`), and `CleanupReport`'s report-wide sums — combine
/// independently-bounded outcomes, and no per-outcome bound can cap that
/// sum in principle. Saturating keeps every REAL total byte-identical
/// (no machine holds anywhere near 9.2 EB, so the clamp is unreachable in
/// the physical regime) and turns the impossible regime into an honest
/// pegged ceiling instead of an arithmetic trap mid-render.
extension Int64 {
    /// `self + other`, clamped to `Int64.min`/`Int64.max` instead of
    /// trapping on overflow.
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        guard overflow else { return sum }
        // Int64 addition can only overflow when both operands share a
        // sign, so the sign of either operand picks the clamped bound.
        return self < 0 ? .min : .max
    }
}
