// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";

/**
 * @title AmplifierLib
 * @notice Silver/Gold/Diamond amplifier eligibility and rate boosts
 * @dev 100-day window from first deposit to achieve amplifiers
 *
 * AMPLIFIERS:
 * - Silver Star: First Salary Achiever → 0.6% ROI, 4x cap
 * - Gold Star: Second Salary Achiever → 0.8% ROI, 5x cap
 * - Diamond Star: Third Salary Achiever → 1.0% ROI, 5x cap
 *
 * Window: 100 days from firstDepositAt
 */

library AmplifierLib {

    // ═══════════════════════════════════════════════════════════════════════
    // AMPLIFIER STATE CHECK
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get user's current amplifier level
     * @return level 0=base, 1=silver, 2=gold, 3=diamond
     */
    function getAmplifierLevel(
        VaultTypes.UserAccount memory user
    ) internal pure returns (uint8 level) {
        if (user.diamondAchieved) return 3;
        if (user.goldAchieved) return 2;
        if (user.silverAchieved) return 1;
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // AMPLIFIER WINDOW CHECK
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if user is within 100-day amplifier window
     */
    function isInAmplifierWindow(
        uint64 firstDepositAt,
        uint64 currentTime
    ) internal pure returns (bool) {
        if (firstDepositAt == 0) return false;
        return currentTime <= (firstDepositAt + VaultConstants.AMPLIFIER_WINDOW);
    }

    /**
     * @notice Get remaining time in amplifier window
     */
    function getRemainingWindowTime(
        uint64 firstDepositAt,
        uint64 currentTime
    ) internal pure returns (uint64) {
        if (firstDepositAt == 0) return 0;
        uint64 windowEnd = firstDepositAt + VaultConstants.AMPLIFIER_WINDOW;
        if (currentTime >= windowEnd) return 0;
        return windowEnd - currentTime;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SILVER AMPLIFIER ELIGIBILITY
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if user qualifies for Silver amplifier
     * @dev Silver = First Salary Tier achieved
     */
    function checkSilverEligibility(
        VaultTypes.UserAccount memory user,
        uint64 currentTime
    ) internal pure returns (bool eligible) {
        if (user.silverAchieved) return false; // Already achieved
        if (!isInAmplifierWindow(user.firstDepositAt, currentTime)) return false;

        // Silver requires Salary Tier 1+ achievement
        return (user.highestPerformanceRank >= 1);
    }

    /**
     * @notice Check if user qualifies for Gold amplifier
     * @dev Gold = Second Salary Tier achieved
     */
    function checkGoldEligibility(
        VaultTypes.UserAccount memory user,
        uint64 currentTime
    ) internal pure returns (bool eligible) {
        if (user.goldAchieved) return false;
        if (!user.silverAchieved) return false; // Must have Silver first
        if (!isInAmplifierWindow(user.firstDepositAt, currentTime)) return false;

        // Gold requires Salary Tier 2+ achievement
        return (user.highestPerformanceRank >= 2);
    }

    /**
     * @notice Check if user qualifies for Diamond amplifier
     * @dev Diamond = Third Salary Tier achieved
     */
    function checkDiamondEligibility(
        VaultTypes.UserAccount memory user,
        uint64 currentTime
    ) internal pure returns (bool eligible) {
        if (user.diamondAchieved) return false;
        if (!user.goldAchieved) return false; // Must have Gold first
        if (!isInAmplifierWindow(user.firstDepositAt, currentTime)) return false;

        // Diamond requires Salary Tier 3+ achievement
        return (user.highestPerformanceRank >= 3);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH ELIGIBILITY CHECK
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check all amplifier eligibilities at once
     * @return silver Eligible for Silver
     * @return gold Eligible for Gold
     * @return diamond Eligible for Diamond
     */
    function checkAllAmplifiers(
        VaultTypes.UserAccount memory user,
        uint64 currentTime
    ) internal pure returns (bool silver, bool gold, bool diamond) {
        silver = checkSilverEligibility(user, currentTime);
        gold = checkGoldEligibility(user, currentTime);
        diamond = checkDiamondEligibility(user, currentTime);
    }

    /**
     * @notice Apply booster flags if the user qualifies within the 100-day window.
     * @dev Booster = salary rank achievement (Silver>=1, Gold>=2, Diamond>=3),
     *      sequential, and only inside 100 days of first deposit. Flags are
     *      permanent once set ("once per lifetime"). Raising the amplifier extends
     *      the ROI cap (2x->3x->4x) and daily rate for the user's active stakes.
     */
    function applyBooster(
        VaultTypes.UserAccount storage user,
        uint64 currentTime
    ) internal {
        if (!isInAmplifierWindow(user.firstDepositAt, currentTime)) return;

        if (!user.silverAchieved && user.highestPerformanceRank >= 1) {
            user.silverAchieved = true;
            user.silverAchievedAt = currentTime;
        }
        if (!user.goldAchieved && user.silverAchieved && user.highestPerformanceRank >= 2) {
            user.goldAchieved = true;
            user.goldAchievedAt = currentTime;
        }
        if (!user.diamondAchieved && user.goldAchieved && user.highestPerformanceRank >= 3) {
            user.diamondAchieved = true;
            user.diamondAchievedAt = currentTime;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RATE & CAP LOOKUP
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get ROI rate based on amplifier level
     */
    function getRateBP(uint8 amplifierLevel) internal pure returns (uint16) {
        if (amplifierLevel == 3) return VaultConstants.DIAMOND_RATE_BP;
        if (amplifierLevel == 2) return VaultConstants.GOLD_RATE_BP;
        if (amplifierLevel == 1) return VaultConstants.SILVER_RATE_BP;
        return VaultConstants.BASE_RATE_BP;
    }

    /**
     * @notice Get cap multiplier based on amplifier level
     */
    function getCapMultiplier(uint8 amplifierLevel) internal pure returns (uint8) {
        if (amplifierLevel == 3) return VaultConstants.DIAMOND_CAP_MULT;
        if (amplifierLevel == 2) return VaultConstants.GOLD_CAP_MULT;
        if (amplifierLevel == 1) return VaultConstants.SILVER_CAP_MULT;
        return VaultConstants.BASE_CAP_MULT;
    }
}
