// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "./BBP_DistributionLib.sol";
import "./BBP_AmplifierLib.sol";

/**
 * @title TeamTierLib
 * @notice External (delegatecall) library holding the heavy leg-business
 *         tracking and tier-achievement detection logic.
 * @dev Marked `public` so it deploys as a SEPARATE contract and is called via
 *      delegatecall — this keeps the main vault bytecode small (under 24KB).
 *      Executes in the vault's storage context, so storage references are valid.
 *
 *      On-chain it ONLY tracks achievements (records who reached which tier and
 *      when). All salary / reward / lifestyle payouts are handled manually
 *      off-chain, exactly as the plan specifies.
 */
library TeamTierLib {

    event SalaryTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event ExpansionTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event LifestyleTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event RewardQueued(address indexed user, uint8 tier, uint128 totalUSD);

    /**
     * @notice Update one upline's leg volumes and detect newly achieved tiers.
     * @param legBusinessUSD storage mapping: user => directLegRoot => volume
     * @param salaryAchievers storage log of salary achievers
     * @param expansionAchievers storage log of expansion achievers
     * @param lifestyleAchievers storage log of lifestyle achievers
     * @param u the upline's account record (storage)
     * @param upline the upline address
     * @param child the direct-leg root the volume flowed through
     * @param amount the staked amount (USD)
     */
    /**
     * @notice Walk up to 50 uplines from a staker, building team volume and
     *         updating leg/tier tracking for each. Moves the whole loop off the
     *         vault to save vault bytecode.
     */
    function distributeTeamVolume(
        mapping(address => VaultTypes.UserAccount) storage users,
        mapping(address => mapping(address => uint128)) storage legBusinessUSD,
        VaultTypes.Achiever[] storage salaryAchievers,
        VaultTypes.Achiever[] storage expansionAchievers,
        VaultTypes.Achiever[] storage lifestyleAchievers,
        mapping(address => VaultTypes.RewardGrant[]) storage rewardQueue,
        address staker,
        uint128 amount
    ) public {
        address child = staker;
        address current = users[staker].referrer;
        for (uint8 level = 1; level <= 50 && current != address(0); ) {
            VaultTypes.UserAccount storage u = users[current];
            u.teamVolumeUSD += amount;
            updateLegAndTiers(
                legBusinessUSD,
                salaryAchievers,
                expansionAchievers,
                lifestyleAchievers,
                rewardQueue[current],
                u,
                current,
                child,
                amount
            );
            child = current;
            current = u.referrer;
            unchecked { ++level; }
        }
    }

    function updateLegAndTiers(
        mapping(address => mapping(address => uint128)) storage legBusinessUSD,
        VaultTypes.Achiever[] storage salaryAchievers,
        VaultTypes.Achiever[] storage expansionAchievers,
        VaultTypes.Achiever[] storage lifestyleAchievers,
        VaultTypes.RewardGrant[] storage rewardQueue,
        VaultTypes.UserAccount storage u,
        address upline,
        address child,
        uint128 amount
    ) public {
        // Update this leg's running volume
        uint128 newLegVol = legBusinessUSD[upline][child] + amount;
        legBusinessUSD[upline][child] = newLegVol;

        // Maintain top-2 legs in O(1)
        if (child == u.strongestLegRoot) {
            u.strongestLegUSD = newLegVol;
        } else if (newLegVol > u.strongestLegUSD) {
            u.secondLegRoot = u.strongestLegRoot;
            u.secondLegUSD = u.strongestLegUSD;
            u.strongestLegRoot = child;
            u.strongestLegUSD = newLegVol;
        } else if (child == u.secondLegRoot) {
            u.secondLegUSD = newLegVol;
        } else if (newLegVol > u.secondLegUSD) {
            u.secondLegRoot = child;
            u.secondLegUSD = newLegVol;
        }

        // Compute leg figures
        uint128 legA = u.strongestLegUSD;
        uint128 legB = u.teamVolumeUSD - legA;            // all other legs
        uint128 leg2 = u.secondLegUSD;
        uint128 leg3 = legB > leg2 ? (legB - leg2) : 0;   // remainder beyond top-2

        // SALARY (2-leg)
        uint8 ns = DistributionLib.advanceSalaryTier(legA, legB, u.highestPerformanceRank);
        if (ns > u.highestPerformanceRank) {
            // Start the salary stream checkpoint on first rank, so salary only
            // accrues from achievement time forward (never retroactively).
            if (u.lastSalaryAccrualTime == 0) {
                u.lastSalaryAccrualTime = uint64(block.timestamp);
            }
            u.highestPerformanceRank = ns;
            u.currentPerformanceRank = ns;
            salaryAchievers.push(VaultTypes.Achiever(upline, ns, uint64(block.timestamp)));
            emit SalaryTierAchieved(upline, ns, block.timestamp);

            // Booster: gaining a salary rank within the 100-day window raises the
            // amplifier (extends ROI cap + daily rate) for this upline's stakes.
            AmplifierLib.applyBooster(u, uint64(block.timestamp));
        }

        // EXPANSION (3-leg) — queue a one-time reward grant per crossed tier.
        // Each grant is released later in 4 installments (6h apart) via claimReward.
        uint8 ne = DistributionLib.advanceExpansionTier(legA, leg2, leg3, u.highestExpansionTier);
        if (ne > u.highestExpansionTier) {
            for (uint8 t = u.highestExpansionTier + 1; t <= ne; ) {
                uint128 reward = DistributionLib.expansionRewardOf(t);
                if (reward > 0) {
                    rewardQueue.push(VaultTypes.RewardGrant(t, reward, 0, uint64(block.timestamp)));
                    emit RewardQueued(upline, t, reward);
                }
                unchecked { ++t; }
            }
            u.highestExpansionTier = ne;
            expansionAchievers.push(VaultTypes.Achiever(upline, ne, uint64(block.timestamp)));
            emit ExpansionTierAchieved(upline, ne, block.timestamp);
        }

        // LIFESTYLE (2-leg)
        uint8 nl = DistributionLib.advanceLifestyleTier(legA, legB, u.lifestyleAchieved);
        if (nl > u.lifestyleAchieved) {
            u.lifestyleAchieved = nl;
            lifestyleAchievers.push(VaultTypes.Achiever(upline, nl, uint64(block.timestamp)));
            emit LifestyleTierAchieved(upline, nl, block.timestamp);
        }
    }
}
