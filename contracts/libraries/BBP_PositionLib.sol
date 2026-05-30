// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./../BBP_Types.sol";
import "./../BBP_Constants.sol";
import "./BBP_RewardLib.sol";

/**
 * @title PositionLib
 * @notice Library for position lifecycle management
 * @dev Handles position creation, updates, and queries
 */

library PositionLib {

    // ═══════════════════════════════════════════════════════════════════════
    // POSITION CREATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create initial position parameters (called during stake)
     * @return pos New position struct with all fields initialized
     */
    function createPosition(
        uint128 depositUSDT,
        uint128 depositBB,
        uint128 lockedPrice,
        uint128 capUSD,
        uint8 amplifierLevel,
        uint64 currentTime
    ) internal pure returns (VaultTypes.Position memory pos) {
        pos.depositUSDT = depositUSDT;
        pos.depositBB = depositBB;
        pos.lockedPrice = lockedPrice;
        pos.capUSD = capUSD;

        // Earned/claimed start at 0
        pos.earnedUSD = 0;
        pos.earnedBB = 0;
        pos.claimedUSD = 0;
        pos.claimedBB = 0;

        // Time tracking
        pos.stakeTime = currentTime;
        pos.lastROIUpdate = currentTime;
        pos.unlockTime = currentTime + VaultConstants.STAKE_TO_CLAIM_GRACE; // 24hr
        pos.lastClaimTime = 0;

        // Status
        pos.amplifierLevel = amplifierLevel;
        pos.active = true;
        pos.capped = false;

        // Income breakdowns start at 0
        pos.protocolBonusUSD = 0;
        pos.protocolStreamUSD = 0;
        pos.protocolFlowUSD = 0;
        pos.performanceTierUSD = 0;
        pos.expansionUSD = 0;
        pos.lifestyleUSD = 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // POSITION UPDATES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update ROI for a position (in-place)
     * @return accruedUSD USD ROI added
     * @return accruedBB BB ROI added
     */
    function updateROI(
        VaultTypes.Position storage pos,
        uint8 amplifierLevel,
        uint64 currentTime
    ) internal returns (uint128 accruedUSD, uint128 accruedBB) {
        if (!pos.active) return (0, 0);
        if (currentTime <= pos.lastROIUpdate) return (0, 0);

        // EARLY EXIT: positions that have ever hit their ROI cap are CLOSED PERMANENTLY.
        // They do NOT accrue further ROI and they do NOT benefit from a later booster cap
        // upgrade. (Open positions only — per the team-network design.)
        if (pos.isClosed) {
            pos.capped = true; // keep dynamic flag in sync
            return (0, 0);
        }

        // Dynamic ROI cap (extends with booster) — only OPEN positions check this.
        uint128 dynCap = uint128(RewardLib.getRoiCapMultiplier(amplifierLevel)) * pos.depositUSDT;
        if (pos.earnedUSD >= dynCap) {
            pos.capped = true;
            pos.isClosed = true; // PERMANENT close on first cap-reach
            return (0, 0);
        }
        pos.capped = false;

        // TIME-BASED auto-compounding: compute TOTAL earned from stake to now
        (uint128 totalUSD, uint128 totalBB) =
            RewardLib.calculateCompoundedEarnings(pos, amplifierLevel, currentTime);

        // The newly accrued portion since last update
        accruedUSD = totalUSD > pos.earnedUSD ? totalUSD - pos.earnedUSD : 0;
        accruedBB = totalBB > pos.earnedBB ? totalBB - pos.earnedBB : 0;

        // Set earned to the compounded total (never decreases)
        if (totalUSD > pos.earnedUSD) {
            pos.earnedUSD = totalUSD;
            pos.earnedBB = totalBB;
        }
        pos.lastROIUpdate = currentTime;

        // INVARIANT: pos.earnedUSD <= dynCap is already guaranteed by
        // RewardLib.calculateCompoundedEarnings (it clamps `profit > capUSD`
        // before returning totalUSD). We rely on that internal clamp so the
        // USD and BB tracks stay perfectly proportional (BB is computed via
        // depositBB × earnedUSD / depositUSDT inside the same function). A
        // redundant clamp here would risk de-syncing the two tracks on a
        // future refactor — do NOT add one.

        // Re-evaluate against dynamic cap; PERMANENTLY close on first cap-reach.
        if (pos.earnedUSD >= dynCap) {
            pos.capped = true;
            pos.isClosed = true;
        }
    }

    /**
     * @notice Record a claim from this position
     * @param claimedUSD USD amount claimed
     * @param claimedBB BB amount claimed
     */
    function recordClaim(
        VaultTypes.Position storage pos,
        uint128 claimedUSD,
        uint128 claimedBB,
        uint64 currentTime
    ) internal {
        pos.claimedUSD += claimedUSD;
        pos.claimedBB += claimedBB;
        pos.lastClaimTime = currentTime;

        // If fully claimed and capped, mark inactive
        if (pos.capped && pos.claimedUSD >= pos.earnedUSD) {
            pos.active = false;
        }
    }

    /**
     * @notice Add income to specific stream (called when team distributes)
     */
    function addIncome(
        VaultTypes.Position storage pos,
        VaultTypes.IncomeType incomeType,
        uint128 amountUSD,
        uint128 amountBB
    ) internal {
        if (!pos.active || pos.capped) return;

        // Check cap - cannot exceed
        uint128 remainingCap = pos.capUSD - pos.earnedUSD;
        if (amountUSD > remainingCap) {
            amountUSD = remainingCap;
            // Proportional BB calc - use locked price
            amountBB = RewardLib.usdToBBAtLockedPrice(amountUSD, pos.lockedPrice);
        }

        if (amountUSD == 0) return;

        // Add to specific breakdown
        if (incomeType == VaultTypes.IncomeType.ProtocolBonus) {
            pos.protocolBonusUSD += amountUSD;
        } else if (incomeType == VaultTypes.IncomeType.ProtocolStream) {
            pos.protocolStreamUSD += amountUSD;
        } else if (incomeType == VaultTypes.IncomeType.ProtocolFlow) {
            pos.protocolFlowUSD += amountUSD;
        } else if (incomeType == VaultTypes.IncomeType.PerformanceTier) {
            pos.performanceTierUSD += amountUSD;
        } else if (incomeType == VaultTypes.IncomeType.Expansion) {
            pos.expansionUSD += amountUSD;
        }

        // Add to totals
        pos.earnedUSD += amountUSD;
        pos.earnedBB += amountBB;

        // INVARIANT: earnedUSD can NEVER exceed capUSD. The remainingCap clamp
        // above mathematically guarantees this — `assert` catches any future
        // refactor or call-path that bypasses the clamp.
        assert(pos.earnedUSD <= pos.capUSD);

        if (pos.earnedUSD >= pos.capUSD) {
            pos.capped = true;
            pos.isClosed = true; // PERMANENT close on cap-reach (paired with capped)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // POSITION QUERIES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if position is claimable (24hr unlock passed)
     */
    function isUnlocked(
        VaultTypes.Position memory pos,
        uint64 currentTime
    ) internal pure returns (bool) {
        return currentTime >= pos.unlockTime;
    }

    /**
     * @notice Get time until unlock
     */
    function getTimeUntilUnlock(
        VaultTypes.Position memory pos,
        uint64 currentTime
    ) internal pure returns (uint64) {
        if (currentTime >= pos.unlockTime) return 0;
        return pos.unlockTime - currentTime;
    }

    /**
     * @notice Calculate live earnings (without state change)
     */
    function getLiveEarnings(
        VaultTypes.Position memory pos,
        uint8 amplifierLevel,
        uint64 currentTime
    ) internal pure returns (
        uint128 totalEarnedUSD,
        uint128 totalEarnedBB,
        uint128 claimableUSD,
        uint128 claimableBB
    ) {
        // TIME-BASED compounded total earned from stake to now
        (uint128 cEarnedUSD, uint128 cEarnedBB) = RewardLib.calculateCompoundedEarnings(
            pos,
            amplifierLevel,
            currentTime
        );

        // earned never decreases below what's already recorded
        totalEarnedUSD = cEarnedUSD > pos.earnedUSD ? cEarnedUSD : pos.earnedUSD;
        totalEarnedBB = cEarnedBB > pos.earnedBB ? cEarnedBB : pos.earnedBB;

        // Claimable = earned - claimed (if unlocked)
        if (currentTime >= pos.unlockTime) {
            claimableUSD = totalEarnedUSD - pos.claimedUSD;
            claimableBB = totalEarnedBB - pos.claimedBB;
        } else {
            claimableUSD = 0;
            claimableBB = 0;
        }
    }
}
