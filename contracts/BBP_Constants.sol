// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title VaultConstants
 * @notice All protocol constants - PDF plan values + hidden contract conditions
 * @dev DO NOT MODIFY these without governance approval - they define the entire plan
 */

library VaultConstants {

    // ═══════════════════════════════════════════════════════════════════════
    // PERCENTAGE MATH
    // ═══════════════════════════════════════════════════════════════════════

    uint256 internal constant PERC_DIVIDER = 10000;     // 100% = 10000 BP
    uint256 internal constant DAY = 1 days;
    // SECURITY: cap compounding horizon well below the _rpow overflow point
    // (~32768 days). The ROI cap is reached by ~278 days, so this never changes
    // any real payout — it only prevents an arithmetic-overflow funds-lock for
    // positions left unclaimed for an extreme time (10y is far past any cap).
    uint256 internal constant MAX_COMPOUND_DAYS = 3650;
    uint256 internal constant SALARY_CYCLE = 30 days;          // monthly maintenance cycle
    uint16  internal constant SALARY_MAINTENANCE_BP = 1000;    // 10% of weaker-leg target
    uint256 internal constant YEAR = 365 days;

    // ═══════════════════════════════════════════════════════════════════════
    // DEPOSIT LIMITS (PDF Page 5)
    // ═══════════════════════════════════════════════════════════════════════

    uint128 internal constant MIN_DEPOSIT = 10e18;        // $10
    uint128 internal constant MAX_DEPOSIT = 5000e18;      // $5,000
    uint128 internal constant DIRECT_MIN_DEPOSIT = 10e18; // $10
    uint128 internal constant REFERRER_MIN_ACTIVE_USD = 25e18; // $25 - referrer must have this staked

    // ═══════════════════════════════════════════════════════════════════════
    // DAILY ROI RATES (Basis Points - PDF Page 6)
    // ═══════════════════════════════════════════════════════════════════════

    uint16 internal constant BASE_RATE_BP = 50;     // 0.50% daily
    uint16 internal constant SILVER_RATE_BP = 60;   // 0.60% daily
    uint16 internal constant GOLD_RATE_BP = 80;     // 0.80% daily
    uint16 internal constant DIAMOND_RATE_BP = 100; // 1.00% daily

    // ═══════════════════════════════════════════════════════════════════════
    // CAP MULTIPLIERS (PDF Page 5 + 6)
    // ═══════════════════════════════════════════════════════════════════════

    uint8 internal constant BASE_CAP_MULT = 3;      // 3x deposit (TOTAL: 2 ROI + 1 working)
    uint8 internal constant SILVER_CAP_MULT = 4;    // 4x deposit (TOTAL: 3 ROI + 1 working)
    uint8 internal constant GOLD_CAP_MULT = 5;      // 5x deposit (TOTAL: 4 ROI + 1 working)
    uint8 internal constant DIAMOND_CAP_MULT = 5;   // 5x deposit (TOTAL: 4 ROI + 1 working)

    // ROI-only cap multipliers (basic return on the stake). Working income adds
    // a further 1x on top, giving the totals above (2+1=3, 3+1=4, 4+1=5, 4+1=5).
    // Booster raises the ROI cap (and the daily rate); working stays at 1x.
    uint8 internal constant BASE_ROI_MULT = 2;      // 2x ROI (no booster)
    uint8 internal constant SILVER_ROI_MULT = 3;    // 3x ROI (booster)
    uint8 internal constant GOLD_ROI_MULT = 4;      // 4x ROI (booster)
    uint8 internal constant DIAMOND_ROI_MULT = 4;   // 4x ROI (booster)

    // Working income cap multiplier — always 1x of total stake, regardless of booster.
    uint8 internal constant WORKING_CAP_MULT = 1;

    // ═══════════════════════════════════════════════════════════════════════
    // BOOSTER WINDOW (PDF Page 6 - "100 DAYS")
    // ═══════════════════════════════════════════════════════════════════════

    uint64 internal constant AMPLIFIER_WINDOW = 100 days;

    // ═══════════════════════════════════════════════════════════════════════
    // STAKE DISTRIBUTION (Per deposit)
    // ═══════════════════════════════════════════════════════════════════════

    uint16 internal constant DEV_FEE_BP = 500;      // 5% to dev wallet
    uint16 internal constant LIQUIDITY_BP = 3500;   // 35% of working to LP
    // Remaining 65% of working amount → swap to BB for vault

    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL FLOW (5% on claims, distributed 50 levels)
    // ═══════════════════════════════════════════════════════════════════════

    uint16 internal constant PROTOCOL_FLOW_DEDUCTION_BP = 500;  // 5% total
    uint16 internal constant PROTOCOL_FLOW_PER_LEVEL_BP = 200;  // 0.1% per level (5%/50)
    uint8  internal constant BB_ACHIEVER_RANK = 2;              // min rank for Protocol Flow (Image 1 #7)
    uint8 internal constant PROTOCOL_FLOW_DEPTH = 50;

    // ═══════════════════════════════════════════════════════════════════════
    // COMMUNITY LEVEL INCOME (PDF Page 8 - 50 levels = 88.50% total)
    // ═══════════════════════════════════════════════════════════════════════

    uint8 internal constant MAX_DISTRIBUTION_DEPTH = 50;

    // Direct requirements per level (PDF Page 8)
    function getRequiredDirects(uint8 level) internal pure returns (uint8) {
        if (level == 0) return 0;
        if (level <= 2) return 1;       // Level 1-2: 1 direct
        if (level <= 4) return 2;       // Level 3-4: 2 directs
        if (level == 5) return 3;       // Level 5: 3 directs
        if (level <= 10) {              // Level 6-10: 4-6 directs
            if (level <= 7) return 4;
            if (level <= 9) return 5;
            return 6;
        }
        if (level <= 20) {              // Level 11-20: 6-10 directs
            if (level <= 13) return 7;
            if (level <= 16) return 8;
            if (level <= 18) return 9;
            return 10;
        }
        if (level <= 30) {              // Level 21-30: 11-15 directs
            if (level <= 22) return 11;
            if (level <= 24) return 12;
            if (level <= 26) return 13;
            if (level <= 28) return 14;
            return 15;
        }
        if (level <= 40) {              // Level 31-40: 16-20 directs
            if (level <= 32) return 16;
            if (level <= 34) return 17;
            if (level <= 36) return 18;
            if (level <= 38) return 19;
            return 20;
        }
        if (level <= 50) {              // Level 41-50: 21-25 directs
            if (level <= 42) return 21;
            if (level <= 44) return 22;
            if (level <= 46) return 23;
            if (level <= 48) return 24;
            return 25;
        }
        return 25;
    }

    // Self topup required per level ($25 per level cumulative)
    function getSelfTopupRequired(uint8 level) internal pure returns (uint128) {
        if (level == 0) return 0;
        return uint128(level) * 25e18;
    }

    // Income percentage per level (basis points)
    function getLevelIncomeBP(uint8 level) internal pure returns (uint16) {
        if (level == 1) return 1000;        // 10%
        if (level == 2) return 800;         // 8%
        if (level == 3) return 700;         // 7%
        if (level == 4) return 600;         // 6%
        if (level == 5) return 500;         // 5%
        if (level <= 10) return 300;        // 3% (levels 6-10)
        if (level <= 20) return 200;        // 2% (levels 11-20)
        if (level <= 30) return 100;        // 1% (levels 21-30)
        if (level <= 40) return 50;         // 0.5% (levels 31-40)
        if (level <= 50) return 25;         // 0.25% (levels 41-50)
        return 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PERFORMANCE SALARY (PDF Page 7 - 13 tiers, 2 Leg Plan)
    // ═══════════════════════════════════════════════════════════════════════

    // Leg A power: 50%, Leg B: all other legs
    uint16 internal constant SALARY_LEG_A_POWER_BP = 5000; // 50%

    /**
     * @notice Get salary tier requirements
     * @param tier 1-13
     * @return legAUSD Required Leg A volume (USD)
     * @return legBUSD Required Leg B volume (USD)
     * @return dailyBonusUSD Daily salary bonus (USD)
     */
    function getSalaryTier(uint8 tier) internal pure returns (
        uint128 legAUSD,
        uint128 legBUSD,
        uint128 dailyBonusUSD
    ) {
        if (tier == 1)  return (2_000e18, 2_000e18, 2e18);          // Starter
        if (tier == 2)  return (6_000e18, 6_000e18, 6e18);          // Achiever
        if (tier == 3)  return (18_000e18, 18_000e18, 18e18);       // Builder
        if (tier == 4)  return (50_000e18, 50_000e18, 40e18);       // Leader
        if (tier == 5)  return (150_000e18, 150_000e18, 70e18);     // Captain
        if (tier == 6)  return (500_000e18, 500_000e18, 125e18);    // Champion
        if (tier == 7)  return (1_500_000e18, 1_500_000e18, 250e18); // Ambassador
        if (tier == 8)  return (5_000_000e18, 5_000_000e18, 500e18); // Director
        if (tier == 9)  return (15_000_000e18, 15_000_000e18, 1_000e18); // Elite Director
        if (tier == 10) return (50_000_000e18, 50_000_000e18, 2_000e18); // Crown Director
        if (tier == 11) return (100_000_000e18, 100_000_000e18, 3_000e18); // Global Leader
        if (tier == 12) return (200_000_000e18, 200_000_000e18, 5_000e18); // Royal Emperor
        if (tier == 13) return (500_000_000e18, 500_000_000e18, 10_000e18); // Big Bull Legend
        return (0, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EXPANSION REWARDS (PDF Page 9 - 13 tiers, 3 Leg Plan)
    // ═══════════════════════════════════════════════════════════════════════

    // Leg 1: 40%, Leg 2: 40%, Leg 3 ALL: 20%
    uint16 internal constant EXPANSION_LEG1_BP = 4000;
    uint16 internal constant EXPANSION_LEG2_BP = 4000;
    uint16 internal constant EXPANSION_LEG3_BP = 2000;

    /**
     * @notice Get expansion tier requirements
     * @param tier 1-13
     * @return leg1USD Required Leg 1 volume
     * @return leg2USD Required Leg 2 volume
     * @return leg3USD Required Leg 3 (all other) volume
     * @return rewardUSD Total reward
     */
    function getExpansionTier(uint8 tier) internal pure returns (
        uint128 leg1USD,
        uint128 leg2USD,
        uint128 leg3USD,
        uint128 rewardUSD
    ) {
        if (tier == 1)  return (2_000e18, 2_000e18, 1_000e18, 200e18);
        if (tier == 2)  return (6_000e18, 6_000e18, 3_000e18, 500e18);
        if (tier == 3)  return (18_000e18, 18_000e18, 9_000e18, 1_500e18);
        if (tier == 4)  return (50_000e18, 50_000e18, 25_000e18, 5_000e18);
        if (tier == 5)  return (150_000e18, 150_000e18, 75_000e18, 15_000e18);
        if (tier == 6)  return (500_000e18, 500_000e18, 250_000e18, 30_000e18);
        if (tier == 7)  return (1_500_000e18, 1_500_000e18, 750_000e18, 50_000e18);
        if (tier == 8)  return (5_000_000e18, 5_000_000e18, 2_500_000e18, 100_000e18);
        if (tier == 9)  return (15_000_000e18, 15_000_000e18, 7_500_000e18, 300_000e18);
        if (tier == 10) return (50_000_000e18, 50_000_000e18, 25_000_000e18, 700_000e18);
        if (tier == 11) return (100_000_000e18, 100_000_000e18, 50_000_000e18, 1_500_000e18);
        if (tier == 12) return (200_000_000e18, 200_000_000e18, 100_000_000e18, 3_000_000e18);
        if (tier == 13) return (500_000_000e18, 500_000_000e18, 250_000_000e18, 5_000_000e18);
        return (0, 0, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIFESTYLE REWARDS (PDF Page 11 - 10 tiers, off-chain)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get lifestyle tier requirements (2 Leg)
     * @dev Lifestyle rewards are tracked on-chain but distributed off-chain
     */
    function getLifestyleTier(uint8 tier) internal pure returns (
        uint128 legAUSD,
        uint128 legBUSD
    ) {
        if (tier == 1)  return (50_000e18, 50_000e18);              // Thailand
        if (tier == 2)  return (150_000e18, 150_000e18);            // Dubai
        if (tier == 3)  return (500_000e18, 500_000e18);            // Singapore
        if (tier == 4)  return (1_500_000e18, 1_500_000e18);        // Maldives
        if (tier == 5)  return (5_000_000e18, 5_000_000e18);        // Europe
        if (tier == 6)  return (15_000_000e18, 15_000_000e18);      // World Tour
        if (tier == 7)  return (50_000_000e18, 50_000_000e18);      // Mercedes
        if (tier == 8)  return (100_000_000e18, 100_000_000e18);    // Land Rover
        if (tier == 9)  return (200_000_000e18, 200_000_000e18);    // Ferrari
        if (tier == 10) return (500_000_000e18, 500_000_000e18);    // Villa
        return (0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // WITHDRAWAL LIMITS
    // ═══════════════════════════════════════════════════════════════════════

    uint128 internal constant MAX_WITHDRAW_USD = 1000e18;       // $1,000 per claim
    uint16 internal constant DAILY_CLAIM_CAP_BP = 2500;         // PRODUCTION: 25% of currentCapUSD per day. Development variant uses 10000 (100%) for compressed-time testing — see development/contracts/VaultConstants.sol

    /// @notice Hard cap on directs per referrer (prevents unbounded array growth
    ///         and gas issues for queries / events / future iterations).
    uint256 internal constant MAX_DIRECTS_PER_REFERRER = 1000;

    // ═══════════════════════════════════════════════════════════════════════
    // TIME LOCKS & COOLDOWNS (Hidden in current contract)
    // ═══════════════════════════════════════════════════════════════════════

    uint64 internal constant DEPOSIT_COOLDOWN = 30 seconds;
    uint64 internal constant ENROLL_TO_DEPOSIT_GRACE = 30 seconds;
    uint64 internal constant REFERRER_FRESH_DEPOSIT_GRACE = 30 seconds;
    uint64 internal constant STAKE_TO_CLAIM_GRACE = 24 hours;   // V4 NEW: 24hr per-stake
    uint64 internal constant CLAIM_COOLDOWN = 2 minutes;
    /// @notice Separate cooldown timer between consecutive claimReward() calls.
    ///         Distinct from CLAIM_COOLDOWN — Performance Rewards have their own pacing,
    ///         so the user can run claim() (regular income) and claimReward() (achievements)
    ///         under independent timers.
    uint64 internal constant REWARD_CLAIM_COOLDOWN = 24 hours;
    uint64 internal constant FIRST_CLAIM_LOCK = 24 hours;       // V4 NEW: 24hr first claim

    // ═══════════════════════════════════════════════════════════════════════
    // VOLUME LIMITS
    // ═══════════════════════════════════════════════════════════════════════

    uint16 internal constant MAX_DAILY_DEPOSITS = 50;       // Per user/day
    uint16 internal constant MAX_STAKES = 100;              // Lifetime per user
    uint16 internal constant DEFAULT_STAKE_LIMIT = 50;
    uint16 internal constant STAKE_LIMIT_INCREMENT = 25;
    uint64 internal constant STAKE_LIMIT_COOLDOWN = 7 days;

    // ═══════════════════════════════════════════════════════════════════════
    // SECURITY FLOORS
    // ═══════════════════════════════════════════════════════════════════════

    uint128 internal constant MIN_LIQUIDITY = 1000e18;          // 1K USDT min
    uint128 internal constant MIN_LIQUIDITY_POST_SWAP = 2000e18; // 2K USDT min

    // ═══════════════════════════════════════════════════════════════════════
    // GENESIS (Root User)
    // ═══════════════════════════════════════════════════════════════════════

    uint128 internal constant ROOT_SEED_DEPOSIT = 200_000e18;            // $200K logical
    uint128 internal constant ROOT_MAX_CAP_USD = 1_000_000_000_000e18;   // $1T unlimited

    // ═══════════════════════════════════════════════════════════════════════
    // PRICE GUARD
    // ═══════════════════════════════════════════════════════════════════════

    uint64 internal constant TWAP_WINDOW = 30 minutes;
    uint16 internal constant MAX_PRICE_DEVIATION_BP = 500;  // 5% max deviation

    /// @notice Hard staleness ceiling. Even though the TWAP auto-refreshes on
    ///         every access once `TWAP_WINDOW` has elapsed, this acts as a
    ///         defensive upper bound. If the oracle has not been touched for
    ///         more than `MAX_ORACLE_AGE`, ANY access reverts — preventing
    ///         use of a wildly outdated cumulative-price reading.
    uint64 internal constant MAX_ORACLE_AGE = 2 hours;
    uint16 internal constant MAX_PRICE_IMPACT_BP = 300;     // 3% max swap impact
    uint16 internal constant DEFAULT_SLIPPAGE_BP = 100;     // 1% slippage default

    // ═══════════════════════════════════════════════════════════════════════
    // GAS GRIEFING PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    uint256 internal constant MIN_GAS_REQUIRED = 500_000;   // 500K gas min

    // ═══════════════════════════════════════════════════════════════════════
    // REFILL TIMELOCK
    // ═══════════════════════════════════════════════════════════════════════

    uint64 internal constant REFILL_TIMELOCK = 24 hours;
    uint128 internal constant MAX_REFILL_PER_DAY = 100_000e18; // 100K BB tokens
}
