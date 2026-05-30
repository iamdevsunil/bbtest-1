// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";

/**
 * @title RewardLib
 * @notice Hybrid ROI calculation library (USD + BB dual tracking)
 * @dev CRITICAL DESIGN:
 *      - USD track for network logic compliance
 *      - BB track for actual payout amounts
 *      - Both update in parallel during ROI accrual
 *      - Cap enforcement matches across both tracks
 */

library RewardLib {

    // ═══════════════════════════════════════════════════════════════════════
    // ROI RATE LOOKUP
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get user's daily ROI rate based on amplifier status
     * @param amplifierLevel 0=base, 1=silver, 2=gold, 3=diamond
     * @return rateBP Daily rate in basis points
     */
    function getRateForLevel(uint8 amplifierLevel) internal pure returns (uint16 rateBP) {
        if (amplifierLevel == 3) return VaultConstants.DIAMOND_RATE_BP; // 100 BP = 1.0%
        if (amplifierLevel == 2) return VaultConstants.GOLD_RATE_BP;    // 80 BP = 0.8%
        if (amplifierLevel == 1) return VaultConstants.SILVER_RATE_BP;  // 60 BP = 0.6%
        return VaultConstants.BASE_RATE_BP;                              // 50 BP = 0.5%
    }

    /**
     * @notice Get cap multiplier based on amplifier
     */
    function getCapMultiplier(uint8 amplifierLevel) internal pure returns (uint8) {
        if (amplifierLevel == 3) return VaultConstants.DIAMOND_CAP_MULT; // 5x total
        if (amplifierLevel == 2) return VaultConstants.GOLD_CAP_MULT;    // 5x total
        if (amplifierLevel == 1) return VaultConstants.SILVER_CAP_MULT;  // 4x total
        return VaultConstants.BASE_CAP_MULT;                              // 3x total
    }

    /**
     * @notice ROI-only cap multiplier (basic return on stake). Extends with booster.
     *         Base 2x, Silver 3x, Gold/Diamond 4x. Working income adds 1x on top.
     */
    function getRoiCapMultiplier(uint8 amplifierLevel) internal pure returns (uint8) {
        if (amplifierLevel == 3) return VaultConstants.DIAMOND_ROI_MULT; // 4x
        if (amplifierLevel == 2) return VaultConstants.GOLD_ROI_MULT;    // 4x
        if (amplifierLevel == 1) return VaultConstants.SILVER_ROI_MULT;  // 3x
        return VaultConstants.BASE_ROI_MULT;                              // 2x
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ROI CALCULATION (Hybrid USD + BB)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate accrued ROI for a position (USD and BB tracks)
     * @dev Pure calculation, does not modify state
     * @param pos Position storage reference
     * @param amplifierLevel Current user amplifier
     * @param currentTime Current timestamp
     * @return accruedUSD USD ROI to add
     * @return accruedBB BB ROI to add (proportional)
     */
    /**
     * @notice Gas-safe fixed-point power: base^exp in WAD (1e18) scale.
     * @dev Binary exponentiation — O(log exp) multiplications, NOT O(exp).
     *      Even 10+ years of days (~3650) costs ~12 iterations. No assembly,
     *      no unbounded loops, so it can never exceed the block gas limit and
     *      lock funds. This is the standard safe accumulator-power pattern.
     */
    function _rpow(uint256 base, uint256 exp, uint256 ONE) internal pure returns (uint256 result) {
        result = ONE;
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * base) / ONE;
            }
            exp >>= 1;
            if (exp > 0) {
                base = (base * base) / ONE;
            }
        }
    }

    /**
     * @notice Total compounded earnings for a position from stake time to now.
     * @dev TIME-BASED auto-compounding: value = principal × (1+r)^days, with a
     *      smooth linear top-up for the partial current day. Returns TOTAL earned
     *      (USD + BB), each capped. BB is kept exactly proportional to USD so the
     *      two tracks can never diverge. One call, no stored intermediate state.
     * @return earnedUSD Total USD earnings so far (capped at capUSD)
     * @return earnedBB  Total BB earnings so far (proportional to earnedUSD)
     */
    function calculateCompoundedEarnings(
        VaultTypes.Position memory pos,
        uint8 amplifierLevel,
        uint64 currentTime
    ) public pure returns (uint128 earnedUSD, uint128 earnedBB) {
        if (currentTime <= pos.stakeTime || pos.depositUSDT == 0) return (0, 0);

        uint256 WAD = 1e18;
        uint16 rateBP = getRateForLevel(amplifierLevel);

        uint64 elapsed = currentTime - pos.stakeTime;
        uint256 fullDays = uint256(elapsed) / VaultConstants.DAY;
        uint256 partialSecs = uint256(elapsed) % VaultConstants.DAY;

        // SECURITY: bound the compounding horizon. _rpow overflows (and would
        // permanently lock a claim) for extreme day counts (~32768+ days). The
        // ROI cap is reached by ~278 days, so clamping here never changes a real
        // payout; it only prevents an arithmetic-overflow DoS on ancient positions.
        if (fullDays > VaultConstants.MAX_COMPOUND_DAYS) {
            fullDays = VaultConstants.MAX_COMPOUND_DAYS;
            partialSecs = 0;
        }

        // Per-day growth factor in WAD: (1 + rateBP/10000)
        uint256 dayFactor = WAD + (uint256(rateBP) * WAD) / VaultConstants.PERC_DIVIDER;

        // Compounded factor over full days (gas-safe binary exponentiation)
        uint256 factor = _rpow(dayFactor, fullDays, WAD);

        // Value after full days of compounding
        uint256 baseValue = (uint256(pos.depositUSDT) * factor) / WAD;

        // Smooth linear growth for the partial (current) day
        uint256 partialGain = (baseValue * rateBP * partialSecs) /
                              (VaultConstants.PERC_DIVIDER * VaultConstants.DAY);

        uint256 grossValue = baseValue + partialGain;
        uint256 profit = grossValue > pos.depositUSDT ? grossValue - pos.depositUSDT : 0;

        // ROI cap is DYNAMIC: roiMult(currentAmplifier) × deposit. When the user
        // clears the booster within 100 days, their amplifier rises and the ROI
        // cap extends (2x → 3x → 4x) for their active stakes automatically.
        uint256 capUSD = uint256(getRoiCapMultiplier(amplifierLevel)) * uint256(pos.depositUSDT);
        if (profit > capUSD) profit = capUSD;
        earnedUSD = uint128(profit);

        // BB earnings kept exactly proportional to USD (same growth + same cap)
        // earnedBB = depositBB × earnedUSD / depositUSDT
        earnedBB = uint128((uint256(pos.depositBB) * profit) / uint256(pos.depositUSDT));
    }

    function calculateROI(
        VaultTypes.Position memory pos,
        uint8 amplifierLevel,
        uint64 currentTime
    ) internal pure returns (uint128 accruedUSD, uint128 accruedBB) {
        if (!pos.active || pos.capped) return (0, 0);
        if (currentTime <= pos.lastROIUpdate) return (0, 0);

        uint64 timeElapsed = currentTime - pos.lastROIUpdate;
        uint16 rateBP = getRateForLevel(amplifierLevel);

        // === USD TRACK ===
        // dailyUSD = deposit × rateBP / 10000
        // accrued = dailyUSD × timeElapsed / 1 day
        uint256 usdCalc = (uint256(pos.depositUSDT) * rateBP * timeElapsed) /
                         (uint256(VaultConstants.PERC_DIVIDER) * VaultConstants.DAY);

        // === BB TRACK ===
        // dailyBB = depositBB × rateBP / 10000
        // accrued = dailyBB × timeElapsed / 1 day
        uint256 bbCalc = (uint256(pos.depositBB) * rateBP * timeElapsed) /
                        (uint256(VaultConstants.PERC_DIVIDER) * VaultConstants.DAY);

        accruedUSD = uint128(usdCalc);
        accruedBB = uint128(bbCalc);

        // === APPLY USD CAP ===
        uint128 remainingUSD = pos.capUSD - pos.earnedUSD;
        if (accruedUSD > remainingUSD) {
            // Cap hit - calculate proportional BB
            accruedUSD = remainingUSD;

            // BB cap (proportional): how much BB matches the remaining USD cap?
            // capBB = depositBB × capMultiplier
            uint8 capMult = getCapMultiplier(amplifierLevel);
            uint128 totalCapBB = pos.depositBB * uint128(capMult);
            uint128 remainingBB = totalCapBB - pos.earnedBB;

            if (accruedBB > remainingBB) {
                accruedBB = remainingBB;
            }
        }
    }

    /**
     * @notice Calculate ROI that WOULD accrue (for view functions)
     * @dev Same as calculateROI but for external view
     */
    function previewROI(
        VaultTypes.Position memory pos,
        uint8 amplifierLevel,
        uint64 currentTime
    ) internal pure returns (uint128 accruedUSD, uint128 accruedBB) {
        return calculateROI(pos, amplifierLevel, currentTime);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CAP CALCULATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate cap USD for a deposit based on amplifier
     */
    function calculateCapUSD(
        uint128 depositUSDT,
        uint8 amplifierLevel
    ) internal pure returns (uint128) {
        // Position ROI cap (basic return): 2x base, extends with booster
        return depositUSDT * uint128(getRoiCapMultiplier(amplifierLevel));
    }

    /**
     * @notice Total payout cap for a stake = ROI cap + 1x working income.
     *         Base 3x, Silver 4x, Gold/Diamond 5x. Used for the user-level cap.
     */
    function calculateTotalCapUSD(
        uint128 depositUSDT,
        uint8 amplifierLevel
    ) internal pure returns (uint128) {
        return depositUSDT * uint128(getCapMultiplier(amplifierLevel));
    }

    /**
     * @notice Check if position has reached cap
     */
    function isCapReached(VaultTypes.Position memory pos) internal pure returns (bool) {
        return pos.earnedUSD >= pos.capUSD;
    }

    /**
     * @notice Get remaining cap in USD
     */
    function getRemainingCapUSD(VaultTypes.Position memory pos) internal pure returns (uint128) {
        if (pos.earnedUSD >= pos.capUSD) return 0;
        return pos.capUSD - pos.earnedUSD;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIMABLE AMOUNTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get claimable USD and BB from a position
     * @dev Returns 0 if position not unlocked (24hr per stake)
     */
    function getClaimable(
        VaultTypes.Position memory pos,
        uint64 currentTime
    ) internal pure returns (uint128 claimableUSD, uint128 claimableBB) {
        if (!pos.active) return (0, 0);
        if (currentTime < pos.unlockTime) return (0, 0); // 24hr lock

        claimableUSD = pos.earnedUSD - pos.claimedUSD;
        claimableBB = pos.earnedBB - pos.claimedBB;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DAILY LIMITS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate daily claim limit (25% of currentCapUSD)
     */
    function getDailyClaimLimit(uint128 currentCapUSD) internal pure returns (uint128) {
        return uint128((uint256(currentCapUSD) * VaultConstants.DAILY_CLAIM_CAP_BP) /
                       VaultConstants.PERC_DIVIDER);
    }

    /**
     * @notice Check if today's claims are within limit
     */
    function isWithinDailyLimit(
        uint128 todayClaimed,
        uint128 attemptUSD,
        uint128 dailyLimit
    ) internal pure returns (bool, uint128 adjustedUSD) {
        if (todayClaimed >= dailyLimit) return (false, 0);

        uint128 remaining = dailyLimit - todayClaimed;
        if (attemptUSD <= remaining) {
            return (true, attemptUSD);
        }
        return (true, remaining);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL FLOW CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate Protocol Flow deduction
     * @return deductionUSD 5% of gross amount
     * @return perLevelUSD Amount per level (deductionUSD / 50)
     */
    function calculateProtocolFlow(uint128 grossUSD) internal pure returns (
        uint128 deductionUSD,
        uint128 perLevelUSD
    ) {
        deductionUSD = uint128((uint256(grossUSD) *
                               VaultConstants.PROTOCOL_FLOW_DEDUCTION_BP) /
                               VaultConstants.PERC_DIVIDER);

        perLevelUSD = uint128((uint256(deductionUSD) *
                              VaultConstants.PROTOCOL_FLOW_PER_LEVEL_BP) /
                              VaultConstants.PERC_DIVIDER);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKE DISTRIBUTION (5/35/60)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate stake distribution amounts
     * @param totalUSDT Total deposit amount
     * @return protocolFee 5% to protocol-fee wallet
     * @return liquidityAmount 35% of working amount to LP
     * @return swapAmount 65% of working amount to swap for BB
     */
    function calculateStakeDistribution(uint128 totalUSDT) internal pure returns (
        uint128 protocolFee,
        uint128 liquidityAmount,
        uint128 swapAmount
    ) {
        protocolFee = uint128((uint256(totalUSDT) * VaultConstants.DEV_FEE_BP) /
                        VaultConstants.PERC_DIVIDER);

        uint128 working = totalUSDT - protocolFee;

        liquidityAmount = uint128((uint256(working) * VaultConstants.LIQUIDITY_BP) /
                                  VaultConstants.PERC_DIVIDER);

        swapAmount = working - liquidityAmount; // Remainder (65% of working)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BB AMOUNT FROM USD (Using locked price per position)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate BB amount from USD using LOCKED price
     * @dev CRITICAL: Uses position's locked price, NOT live price
     * @param amountUSD USD amount to convert
     * @param lockedPrice Price stored in position (immutable per position)
     * @return amountBB BB tokens equivalent
     */
    function usdToBBAtLockedPrice(
        uint128 amountUSD,
        uint128 lockedPrice
    ) internal pure returns (uint128 amountBB) {
        if (lockedPrice == 0) return 0;
        amountBB = uint128((uint256(amountUSD) * 1e18) / uint256(lockedPrice));
    }

    /**
     * @notice Calculate USD value from BB at locked price
     */
    function bbToUSDAtLockedPrice(
        uint128 amountBB,
        uint128 lockedPrice
    ) internal pure returns (uint128 amountUSD) {
        amountUSD = uint128((uint256(amountBB) * uint256(lockedPrice)) / 1e18);
    }
}
