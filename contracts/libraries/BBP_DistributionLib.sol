// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";
import "./BBP_RewardLib.sol";

/**
 * @title DistributionLib
 * @notice team matching distribution logic + Protocol Flow with DAO Governor
 * @dev Pure calculation functions - state changes done in main contract
 *
 * KEY FEATURES:
 * - 50-level Protocol Flow distribution
 * - Skipped portions → DAO Governor wallet
 * - Direct/topup qualification checks
 * - Volume tracking (USD-based)
 */

library DistributionLib {

    // ═══════════════════════════════════════════════════════════════════════
    // QUALIFICATION CHECKS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if upline qualifies for a specific level
     * @param level Level being checked (1-50)
     * @param directsCount Number of direct referrals
     * @param selfTopupUSD Self topup amount (lifetime)
     * @return qualified True if upline can receive income at this level
     */
    function isQualifiedForLevel(
        uint8 level,
        uint32 directsCount,
        uint128 selfTopupUSD
    ) public pure returns (bool qualified) {
        if (level == 0 || level > 50) return false;

        uint8 requiredDirects = VaultConstants.getRequiredDirects(level);
        uint128 requiredTopup = VaultConstants.getSelfTopupRequired(level);

        return (directsCount >= requiredDirects && selfTopupUSD >= requiredTopup);
    }

    /**
     * @notice Get income percentage for a specific level
     */
    function getLevelIncomePercentBP(uint8 level) internal pure returns (uint16) {
        return VaultConstants.getLevelIncomeBP(level);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL FLOW DISTRIBUTION (5% on claims)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Distribution result for Protocol Flow
     */
    struct ProtocolFlowResult {
        uint128 totalDeduction;        // 5% of gross
        uint128 perLevel;               // Per-level amount (5%/50)
        uint128 totalToUplines;         // Sum to qualified uplines
        uint128 totalToDAO;             // Sum to DAO Governor
        address[] uplinePayees;         // Array of payee addresses
        uint128[] uplineAmounts;        // Corresponding amounts
        uint8[] uplineLevels;           // Corresponding levels
        uint8 payCount;                 // Number of payees
    }

    /**
     * @notice Calculate Protocol Flow distribution amounts
     * @dev PURE calculation - actual state checks in main contract
     * @param grossUSD Gross claim amount before deduction
     */
    function calculateProtocolFlowDeduction(uint128 grossUSD) public pure returns (
        uint128 deduction,
        uint128 perLevel
    ) {
        deduction = uint128((uint256(grossUSD) *
                            VaultConstants.PROTOCOL_FLOW_DEDUCTION_BP) /
                            VaultConstants.PERC_DIVIDER);

        perLevel = uint128((uint256(deduction) *
                           VaultConstants.PROTOCOL_FLOW_PER_LEVEL_BP) /
                           VaultConstants.PERC_DIVIDER);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VOLUME UPDATES (USD-based for team)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Determine which leg gets the new business
     * @dev Tracks strongest leg + second leg for salary/expansion qualification
     */
    function updateLegVolumes(
        uint128 currentStrongest,
        uint128 currentSecond,
        uint128 newBusinessUSD,
        bool isFromStrongestLeg
    ) internal pure returns (uint128 newStrongest, uint128 newSecond) {
        if (isFromStrongestLeg) {
            newStrongest = currentStrongest + newBusinessUSD;
            newSecond = currentSecond;
        } else {
            // Update second leg
            uint128 candidate = currentSecond + newBusinessUSD;
            if (candidate > currentStrongest) {
                // Swap: candidate becomes strongest
                newStrongest = candidate;
                newSecond = currentStrongest;
            } else {
                newStrongest = currentStrongest;
                newSecond = candidate;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SALARY TIER CHECK
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check eligible salary tier based on leg volumes
     * @dev 2-leg plan: Leg A (50% power) + Leg B (all other)
     * @return tier 0 = none, 1-13 = qualified tier
     */
    function checkSalaryTier(
        uint128 legAUSD,
        uint128 legBUSD
    ) public pure returns (uint8 tier) {
        // Check from highest to lowest
        for (uint8 i = 13; i >= 1; i--) {
            (uint128 reqA, uint128 reqB, ) = VaultConstants.getSalaryTier(i);
            if (legAUSD >= reqA && legBUSD >= reqB) {
                return i;
            }
            if (i == 1) break; // Prevent underflow
        }
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXPANSION TIER CHECK (3-Leg)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check eligible expansion tier
     * @dev 3-leg plan: Leg 1 (40%) + Leg 2 (40%) + Leg 3 (20%)
     */
    function checkExpansionTier(
        uint128 leg1USD,
        uint128 leg2USD,
        uint128 leg3USD
    ) public pure returns (uint8 tier) {
        for (uint8 i = 13; i >= 1; i--) {
            (uint128 r1, uint128 r2, uint128 r3, ) = VaultConstants.getExpansionTier(i);
            if (leg1USD >= r1 && leg2USD >= r2 && leg3USD >= r3) {
                return i;
            }
            if (i == 1) break;
        }
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFESTYLE TIER CHECK
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check eligible lifestyle tier (2-leg)
     */
    function checkLifestyleTier(
        uint128 legAUSD,
        uint128 legBUSD
    ) public pure returns (uint8 tier) {
        for (uint8 i = 10; i >= 1; i--) {
            (uint128 reqA, uint128 reqB) = VaultConstants.getLifestyleTier(i);
            if (legAUSD >= reqA && legBUSD >= reqB) {
                return i;
            }
            if (i == 1) break;
        }
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MATCHING INCOME CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate matching income for a specific level
     * @param depositUSD Amount being deposited
     * @param level Level (1-50) of upline from depositor
     */
    function calculateLevelMatching(
        uint128 depositUSD,
        uint8 level
    ) public pure returns (uint128 matchingUSD) {
        uint16 levelBP = VaultConstants.getLevelIncomeBP(level);
        if (levelBP == 0) return 0;

        matchingUSD = uint128((uint256(depositUSD) * levelBP) /
                              VaultConstants.PERC_DIVIDER);
    }

    /**
     * @notice Accrue salary with the 10% weaker-leg monthly maintenance rule.
     * @dev Salary accrues by rank, but only while the user keeps generating at
     *      least 10% of their rank's weaker-leg target as FRESH business in the
     *      current 30-day cycle. The cycle baseline resets every 30 days, so fresh
     *      10% is required each month. Accrual is bounded to the current cycle
     *      (max(lastAccrual, cycleStart) → now) so non-compliant or pre-cycle time
     *      is never paid. If not compliant, nothing accrues until 10% is met within
     *      the cycle. Weaker leg = teamVolume − strongestLeg (the all-other side).
     */
    function accrueSalaryWithMaintenance(
        VaultTypes.UserAccount storage u,
        uint64 nowT
    ) public returns (uint128 salaryUSD) {
        uint8 rank = u.highestPerformanceRank;
        if (rank == 0) {
            u.lastSalaryAccrualTime = nowT;
            return 0;
        }

        uint128 legB = u.teamVolumeUSD > u.strongestLegUSD
            ? u.teamVolumeUSD - u.strongestLegUSD
            : 0;

        // Initialise or roll the 30-day maintenance cycle (no loop)
        if (u.salaryCycleStart == 0) {
            u.salaryCycleStart = nowT;
            u.salaryCycleStartLegB = legB;
        } else if (nowT >= u.salaryCycleStart + VaultConstants.SALARY_CYCLE) {
            uint64 cycles = (nowT - u.salaryCycleStart) / uint64(VaultConstants.SALARY_CYCLE);
            u.salaryCycleStart += cycles * uint64(VaultConstants.SALARY_CYCLE);
            u.salaryCycleStartLegB = legB; // new baseline → must generate fresh 10%
        }

        // Required fresh weaker-leg business = 10% of this rank's weaker-leg target
        (, uint128 legBTarget, uint128 dailyBonus) = VaultConstants.getSalaryTier(rank);
        uint128 required = uint128(
            (uint256(legBTarget) * VaultConstants.SALARY_MAINTENANCE_BP) / VaultConstants.PERC_DIVIDER
        );
        uint128 fresh = legB > u.salaryCycleStartLegB ? legB - u.salaryCycleStartLegB : 0;

        if (fresh >= required) {
            // Compliant: accrue from max(lastAccrual, cycleStart) to now
            uint64 start = u.lastSalaryAccrualTime > u.salaryCycleStart
                ? u.lastSalaryAccrualTime
                : u.salaryCycleStart;
            if (nowT > start) {
                uint256 elapsed = uint256(nowT) - uint256(start);
                salaryUSD = uint128((uint256(dailyBonus) * elapsed) / VaultConstants.DAY);
            }
            u.lastSalaryAccrualTime = nowT;
        }
        // Not compliant: no accrual; checkpoint preserved so the cycle's salary can
        // still be claimed once 10% fresh business is generated within the cycle.
    }

    /**
     * @notice Accrued salary (USD) for a rank since the last checkpoint.
     * @dev Daily bonus from the salary tier table × elapsed days. Returns 0 if
     *      no rank, no checkpoint yet, or no time elapsed.
     */
    function accruedSalaryUSD(
        uint8 rank,
        uint64 lastTime,
        uint64 nowT
    ) public pure returns (uint128) {
        if (rank == 0 || lastTime == 0 || nowT <= lastTime) return 0;
        (, , uint128 dailyBonus) = VaultConstants.getSalaryTier(rank);
        uint256 elapsed = uint256(nowT) - uint256(lastTime);
        return uint128((uint256(dailyBonus) * elapsed) / VaultConstants.DAY);
    }

    /**
     * @notice Distribute BOTH Community Level Income (on ROI) and Protocol Flow
     *         (on the claim deduction) in a SINGLE 50-level walk.
     * @dev Gas optimization: previously these were two separate walks over the
     *      same uplines (each upline loaded twice, referrer followed twice). This
     *      loads each upline once and credits both incomes in one pass — same
     *      outcome, roughly half the walk gas. Breaks early when the chain ends,
     *      routing the remaining Protocol Flow levels to the DAO.
     * @param roiUSD       the ROI this claimer generated (level income basis)
     * @param flowPerLevel per-level Protocol Flow amount (0.1% of gross)
     * @return daoAccumulated Protocol Flow that fell through to the DAO
     */
    function distributeUplineIncome(
        mapping(address => VaultTypes.UserAccount) storage users,
        address claimer,
        uint128 roiUSD,
        uint128 flowPerLevel
    ) public returns (uint128 daoAccumulated) {
        address current = users[claimer].referrer;

        for (uint8 level = 1; level <= 50; ) {
            if (current == address(0)) {
                // Chain ended: ALL remaining levels' shares (BOTH income types) → DAO.
                // This implements the team-network spec: "if level is missing/no-one,
                // accumulate through all 50 levels and send to the company wallet".
                if (roiUSD > 0) {
                    for (uint8 l = level; l <= 50; ) {
                        daoAccumulated += calculateLevelMatching(roiUSD, l);
                        unchecked { ++l; }
                    }
                }
                if (flowPerLevel > 0) {
                    daoAccumulated += flowPerLevel * (50 - level + 1);
                }
                break;
            }

            VaultTypes.UserAccount storage u = users[current];
            bool notCapped = !u.isCapped;

            // (1) COMMUNITY LEVEL INCOME — on the claimer's ROI. Needs enough
            //     ACTIVE directs + self stake ($25 × level) for this level.
            //     If the upline is CAPPED or NOT QUALIFIED, the share routes to
            //     the DAO (team-network spec — no income is "lost").
            if (roiUSD > 0) {
                uint128 lvlInc = calculateLevelMatching(roiUSD, level);
                if (lvlInc > 0) {
                    if (notCapped && isQualifiedForLevel(level, u.activeDirectsCount, u.totalDepositUSD)) {
                        u.pendingProtocolStream += lvlInc;
                    } else {
                        daoAccumulated += lvlInc; // ← treasury fallback (NEW: BB-11)
                    }
                }
            }

            // (2) PROTOCOL FLOW — needs minimum rank BB-Achiever (Image 1 #7).
            //     Unqualified / capped uplines' share routes to the DAO.
            if (flowPerLevel > 0) {
                if (u.highestPerformanceRank >= VaultConstants.BB_ACHIEVER_RANK && notCapped) {
                    u.pendingProtocolFlow += flowPerLevel;
                } else {
                    daoAccumulated += flowPerLevel;
                }
            }

            current = u.referrer;
            unchecked { ++level; }
        }
    }

    /**
     * @notice One-time Performance Reward amount for a single expansion tier.
     */
    function expansionRewardOf(uint8 tier) public pure returns (uint128) {
        (, , , uint128 reward) = VaultConstants.getExpansionTier(tier);
        return reward;
    }

    /**
     * @notice Sum of one-time Performance Rewards for tiers (fromTier, toTier].
     */
    function sumExpansionRewards(uint8 fromTier, uint8 toTier)
        public pure returns (uint128 total)
    {
        for (uint8 t = fromTier + 1; t <= toTier && t <= 13; ) {
            (, , , uint128 reward) = VaultConstants.getExpansionTier(t);
            total += reward;
            unchecked { ++t; }
        }
    }

    /**
     * @notice Accrue salary, then collect all pending streams up to remainingCap.
     * @dev Streams paid in priority order: level stream, Protocol Flow, salary,
     *      one-time rewards. Paid amounts are deducted from storage BEFORE the
     *      caller transfers (checks-effects-interactions). Returns USD collected.
     */
    function collectPending(
        VaultTypes.UserAccount storage u,
        uint64 nowT,
        uint128 remainingCap
    ) public returns (uint128 usd) {
        // Accrue salary stream (with 10% weaker-leg monthly maintenance) into its bucket
        uint128 sal = accrueSalaryWithMaintenance(u, nowT);
        if (sal > 0) u.pendingPerformanceTier += sal;

        uint128 total = u.pendingProtocolStream + u.pendingProtocolFlow +
                        u.pendingPerformanceTier + u.pendingExpansion;
        if (total == 0 || remainingCap == 0) return 0;

        // UNIFIED WORKING CAP: ALL working streams (level + flow + salary + Performance
        // Rewards/expansion) are bounded by the 1X working cap. When the cap is hit, the
        // unpaid amounts STAY in their pending buckets — they are NOT lost. As soon as
        // the user takes a new stake (which grows totalDepositUSD and therefore workingCap),
        // those pending balances become claimable again on the next claim. This is the
        // "income hold / release on new stake" behaviour required by the team-network spec
        // (replaces the earlier BB-07 absolute bypass with a held-release model — better
        // for small-stake users: their big achievement rewards aren't lost, just deferred).
        uint128 workingCap = u.totalDepositUSD * VaultConstants.WORKING_CAP_MULT; // 1x
        uint128 workingAvail = workingCap > u.workingEarnedUSD
            ? workingCap - u.workingEarnedUSD
            : 0;
        if (workingAvail == 0) return 0;

        // Pay the lesser of: daily cap remaining, working-cap remaining, total pending
        uint128 limit = remainingCap < workingAvail ? remainingCap : workingAvail;
        usd = total > limit ? limit : total;

        uint128 pay = usd;
        uint128 take;

        // Priority: level income → upline flow → salary → Performance Rewards
        take = u.pendingProtocolStream < pay ? u.pendingProtocolStream : pay;
        u.pendingProtocolStream -= take; pay -= take;

        take = u.pendingProtocolFlow < pay ? u.pendingProtocolFlow : pay;
        u.pendingProtocolFlow -= take; pay -= take;

        take = u.pendingPerformanceTier < pay ? u.pendingPerformanceTier : pay;
        u.pendingPerformanceTier -= take; pay -= take;

        take = u.pendingExpansion < pay ? u.pendingExpansion : pay;
        u.pendingExpansion -= take; pay -= take;

        // Record working income paid against the 1x cap
        u.workingEarnedUSD += usd;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TIER ADVANCEMENT (incremental - cheap gas)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Advance salary tier (2-leg) as far as the legs now qualify.
     * @param legA Strongest leg volume
     * @param legB All-other-legs volume
     * @param currentTier Current highest salary tier (0-13)
     * @return newTier Updated highest tier
     */
    function advanceSalaryTier(
        uint128 legA,
        uint128 legB,
        uint8 currentTier
    ) public pure returns (uint8 newTier) {
        newTier = currentTier;
        while (newTier < 13) {
            (uint128 reqA, uint128 reqB, ) = VaultConstants.getSalaryTier(newTier + 1);
            if (legA >= reqA && legB >= reqB) {
                newTier++;
            } else {
                break;
            }
        }
    }

    /**
     * @notice Advance expansion tier (3-leg) as far as the legs now qualify.
     */
    function advanceExpansionTier(
        uint128 leg1,
        uint128 leg2,
        uint128 leg3,
        uint8 currentTier
    ) public pure returns (uint8 newTier) {
        newTier = currentTier;
        while (newTier < 13) {
            (uint128 r1, uint128 r2, uint128 r3, ) = VaultConstants.getExpansionTier(newTier + 1);
            if (leg1 >= r1 && leg2 >= r2 && leg3 >= r3) {
                newTier++;
            } else {
                break;
            }
        }
    }

    /**
     * @notice Advance lifestyle tier (2-leg) as far as the legs now qualify.
     */
    function advanceLifestyleTier(
        uint128 legA,
        uint128 legB,
        uint8 currentTier
    ) public pure returns (uint8 newTier) {
        newTier = currentTier;
        while (newTier < 10) {
            (uint128 reqA, uint128 reqB) = VaultConstants.getLifestyleTier(newTier + 1);
            if (legA >= reqA && legB >= reqB) {
                newTier++;
            } else {
                break;
            }
        }
    }
}
