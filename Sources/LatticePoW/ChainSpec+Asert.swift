import LatticePrimitives
import UInt256

// MARK: - Target Calculations
public extension ChainSpec {

    private func elapsedMilliseconds(later: Int64, earlier: Int64) -> UInt64 {
        guard later > earlier else { return 0 }
        if earlier >= 0 || later < 0 {
            return UInt64(later - earlier)
        }
        return UInt64(later) + UInt64(-(earlier + 1)) + 1
    }

    private func multiplyDividingSaturating(_ value: UInt256, by numerator: UInt256, over denominator: UInt256) -> UInt256 {
        guard denominator > .zero else { return UInt256.max }
        guard numerator > .zero else { return .zero }

        let (quotient, remainder) = UInt256.divisionWithRemainder(value, denominator)
        let limit = UInt256.max / numerator

        let scaledQuotient = quotient > limit ? UInt256.max : quotient * numerator
        let scaledRemainderProduct = remainder > limit ? UInt256.max : remainder * numerator
        let scaledRemainder = scaledRemainderProduct / denominator

        return scaledQuotient > UInt256.max - scaledRemainder
            ? UInt256.max
            : scaledQuotient + scaledRemainder
    }

    /// The difficulty schedule: an absolutely-scheduled exponential target.
    ///
    /// The target for a block is a function of ONE anchor and this block's own
    /// height and timestamp:
    ///
    ///     target = anchorTarget * 2^((elapsed - targetBlockTime * heights) / halfLife)
    ///
    /// where `elapsed` is the time since the anchor and `heights` is the number
    /// of blocks since it. When the chain is exactly on schedule the exponent is
    /// zero and the target is the anchor's. Running ahead of schedule hardens
    /// it, running behind eases it, smoothly and without bound in either
    /// direction.
    ///
    /// **There is no window, and that is the point.** A windowed average carries
    /// its last intervals as state, so a stretch of unusual
    /// block times keeps steering difficulty long after it has passed, and a
    /// window perturbed at one end oscillates as it drains. This reads only the
    /// anchor and the present block, so it has nothing to drain: a disturbance
    /// stops mattering the moment it stops happening.
    ///
    /// It is also why the genesis timestamp cannot poison this schedule. A
    /// window that reaches back to genesis reads the gap before block 1 as one
    /// colossal solve time -- on a chain stamping genesis at epoch 0 that gap is
    /// decades, and the estimator eases every block until it finally ages out.
    /// Anchored at block 1, genesis is simply never read.
    ///
    /// The anchor must be a block whose target is near what the chain can
    /// actually sustain. This moves at most one doubling per half-life, so an
    /// anchor far from the truth is approached slowly -- from a maximum target
    /// that is dozens of half-lives, spent at negligible difficulty.
    ///
    /// Integer-exact by construction. Every node must compute the identical
    /// target from the identical inputs, so the exponential is evaluated in
    /// 16.16 fixed point with a cubic approximation over the fractional part --
    /// the same shape Bitcoin Cash's `aserti3-2d` uses, and for the same reason.
    /// No floating point appears anywhere in this path.
    func calculateAsertTarget(
        anchorTarget: UInt256,
        anchorTimestamp: Int64,
        anchorHeight: UInt64,
        blockTimestamp: Int64,
        blockHeight: UInt64
    ) -> UInt256 {
        guard blockHeight > anchorHeight else { return anchorTarget }
        let halfLifeMilliseconds = halfLifeMilliseconds()
        guard halfLifeMilliseconds > 0 else { return anchorTarget }
        // A zero anchor target expresses no schedule: every scaling of zero is
        // zero, so the doubling below could never climb out of it however long
        // it ran. An anchor read from an unvalidated ancestor can carry one, so
        // this is a reachable input and not merely a defensive check.
        guard anchorTarget != .zero else { return UInt256(1) }

        // How far ahead of (negative) or behind (positive) schedule we are, in
        // milliseconds. Both terms are clamped before use: `blockTimestamp` is
        // attacker-supplied on an unconnected block, and the height difference
        // is bounded by the chain itself.
        let heights = blockHeight - anchorHeight
        let product = heights.multipliedReportingOverflow(by: targetBlockTime)
        let scheduled = Int64(clamping: product.overflow ? UInt64.max : product.partialValue)
        // A timestamp at or before the anchor yields zero elapsed, which makes
        // the drift maximally negative and the target harder. Moving a block's
        // clock backwards therefore costs the miner difficulty rather than
        // buying any, so the clamp needs no separate defence.
        let elapsed = Int64(clamping: elapsedMilliseconds(
            later: blockTimestamp, earlier: anchorTimestamp
        ))
        let deviation = elapsed.subtractingReportingOverflow(scheduled)
        let driftMilliseconds = deviation.overflow
            ? (scheduled > 0 ? Int64.min : Int64.max)
            : deviation.partialValue

        // 16.16 fixed-point exponent. The drift is bounded first so the scaling
        // multiply cannot overflow: past this magnitude the target saturates
        // anyway, so the clamp changes no reachable result.
        let maximumDrift = Int64.max / Self.asertFixedPointOne
        let boundedDrift = min(max(driftMilliseconds, -maximumDrift), maximumDrift)
        let exponent = (boundedDrift * Self.asertFixedPointOne) / halfLifeMilliseconds

        // Arithmetic shift floors toward negative infinity, so `fraction` is
        // always the non-negative remainder and `doublings` carries the sign.
        let doublings = exponent >> Self.asertFixedPointBits
        let fraction = UInt64(exponent & (Self.asertFixedPointOne - 1))

        // Cubic approximation of 2^(fraction/65536) in 16.16, exact in integers.
        // The constants are chosen so the widest intermediate stays inside
        // UInt64; see the overflow note on `asertCubic*`.
        let cubic = Self.asertCubicA * fraction
            + Self.asertCubicB * fraction * fraction
            + Self.asertCubicC * fraction * fraction * fraction
            + Self.asertCubicRounding
        let factor = UInt64(Self.asertFixedPointOne) + (cubic >> 48)

        // target = anchorTarget * factor / 2^16, shifted by the whole doublings.
        //
        // HARDENING folds its halvings into the DIVISOR rather than applying
        // them afterwards. `factor` is in [1, 2), so multiplying first pushes a
        // target near the maximum past what 256 bits can hold; that saturates,
        // and the halvings then come off the saturated value instead of the
        // true product. An anchor at the maximum target one block ahead of
        // schedule -- the ordinary state of a chain just after launch -- came
        // out at exactly half the maximum instead of 0.994 of it, a whole
        // doubling wrong. Dividing once, by 2^(16 + halvings), never overflows
        // and never saturates early.
        //
        // EASING can keep multiplying first: saturation there is the right
        // answer, because a result too large to represent is the maximum.
        if doublings < 0 {
            let halvings = -doublings
            // Past this the divisor itself leaves 256 bits, so the true value
            // has already rounded to nothing and the hardest target is correct.
            guard halvings < Self.asertMaximumDoublings - Int64(Self.asertFixedPointBits)
            else { return UInt256(1) }
            let scaled = multiplyDividingSaturating(
                anchorTarget,
                by: UInt256(factor),
                over: UInt256(1) << UInt256(UInt64(halvings) + UInt64(Self.asertFixedPointBits))
            )
            return scaled == .zero ? UInt256(1) : scaled
        }
        var scaled = multiplyDividingSaturating(
            anchorTarget,
            by: UInt256(factor),
            over: UInt256(UInt64(Self.asertFixedPointOne))
        )
        // The shift is bounded by the width of the type rather than by the
        // drift, which is attacker-supplied: no 256-bit value stays
        // representable through 256 doublings, so past that it is the maximum.
        if doublings > 0 {
            guard doublings < Self.asertMaximumDoublings else { return UInt256.max }
            let ceiling = UInt256.max / UInt256(2)
            for _ in 0..<doublings {
                guard scaled <= ceiling else { return UInt256.max }
                scaled = scaled * UInt256(2)
            }
        }
        return scaled == .zero ? UInt256(1) : scaled
    }

    /// The committed half-life in block time; saturating, since both factors
    /// are the chain's own unbounded choices.
    func halfLifeMilliseconds() -> Int64 {
        let product = halfLife.multipliedReportingOverflow(by: targetBlockTime)
        guard !product.overflow else { return Int64.max }
        return Int64(clamping: product.partialValue)
    }

    private static let asertFixedPointBits: Int64 = 16
    private static let asertFixedPointOne: Int64 = 1 << 16
    /// One more than the width of the target, so the shift saturates instead of
    /// iterating on an attacker-supplied count.
    private static let asertMaximumDoublings: Int64 = 256
    // 2^(x/65536) ~= 1 + ax + bx^2 + cx^3 in 16.16, with the sum taken at 2^48
    // and rounded. At the widest fraction (65535) the three terms total just
    // under UInt64.max, which is what fixes these particular constants.
    private static let asertCubicA: UInt64 = 195_766_423_245_049
    private static let asertCubicB: UInt64 = 971_821_376
    private static let asertCubicC: UInt64 = 5_127
    private static let asertCubicRounding: UInt64 = 1 << 47
}
