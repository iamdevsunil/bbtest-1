// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title VaultTypes
 * @notice All structs, enums, and type definitions for BigBull V4
 * @dev Centralized type definitions to avoid duplication across contracts
 *
 * HYBRID DESIGN PHILOSOPHY:
 * - USD tracking for network logic (PDF plan compliance)
 * - BB token tracking for actual payouts
 * - Locked prices per position (no live price at claim)
 */

library VaultTypes {

    // ═══════════════════════════════════════════════════════════════════════
    // POSITION STRUCT (Per Stake - Hybrid USD + BB)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Single staking position with hybrid USD/BB tracking
     * @dev Each stake creates a new Position. Multiple positions per user allowed.
     */
    struct Position {
        // === USD Reference (for team compliance) ===
        uint128 depositUSDT;        // Original USDT amount deposited
        uint128 capUSD;             // Total USD cap (3x/4x/5x of deposit)
        uint128 earnedUSD;          // Total USD ROI accrued
        uint128 claimedUSD;         // Total USD already claimed

        // === BB Token (for actual payout) ===
        uint128 depositBB;          // BB tokens at deposit (locked price)
        uint128 lockedPrice;        // USD price at deposit time
        uint128 earnedBB;           // BB tokens accrued as ROI
        uint128 claimedBB;          // BB tokens already transferred

        // === Time Tracking ===
        uint64 stakeTime;           // When position was created
        uint64 unlockTime;          // When user can claim (stakeTime + 24h)
        uint64 lastROIUpdate;       // Last ROI accrual timestamp
        uint64 lastClaimTime;       // Last claim from this position

        // === Income Breakdowns (USD per stake) ===
        uint128 protocolBonusUSD;    // Direct referral income
        uint128 protocolStreamUSD;   // Level/depth income
        uint128 protocolFlowUSD;     // Upstream flow income
        uint128 performanceTierUSD;  // Salary/rank income
        uint128 expansionUSD;        // 3-leg achievement income
        uint128 lifestyleUSD;        // Lifestyle achievement (off-chain)

        // === Status Flags ===
        uint8 amplifierLevel;       // 0=base, 1=silver, 2=gold, 3=diamond
        bool active;                // Position active
        bool capped;                // Cap reached (earnedUSD >= capUSD)
        bool isClosed;              // Explicit close status (set when capped is first hit)
                                    // Closed positions DO NOT accrue further ROI and do NOT
                                    // benefit from later booster cap-multiplier upgrades.
                                    // Only OPEN positions (capped=false, isClosed=false) get
                                    // booster ROI-cap growth.
    }

    // ═══════════════════════════════════════════════════════════════════════
    // USER team STRUCT (Per User - Aggregate Tracking)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice User-level team and lifetime tracking
     * @dev Aggregate stats across all positions for network logic
     */
    struct UserAccount {
        // === team Tree ===
        address referrer;               // Who introduced this user
        uint32 directsCount;            // Number of direct referrals
        uint32 activeDirectsCount;      // Active directs (with deposits)

        // === Lifetime USD ===
        uint128 totalDepositUSD;        // Sum of all deposits
        uint128 totalEarnedUSD;         // Sum of all earnings
        uint128 totalClaimedUSD;        // Sum of all claims
        uint128 currentCapUSD;          // Current lifetime cap

        // === Lifetime BB ===
        uint128 totalDepositBB;         // Sum of BB at deposits
        uint128 totalClaimedBB;         // Sum of BB claimed

        // === Volume Tracking (USD for team) ===
        uint128 directBusinessUSD;      // Volume from direct referrals
        uint128 teamVolumeUSD;          // Total team volume
        uint128 strongestLegUSD;        // Strongest leg volume
        uint128 secondLegUSD;           // Second leg volume
        address strongestLegRoot;       // direct that roots the strongest leg
        address secondLegRoot;          // direct that roots the second leg

        // === Pending Reserves (USD) ===
        uint128 pendingProtocolBonus;
        uint128 pendingProtocolStream;
        uint128 pendingProtocolFlow;
        uint128 pendingPerformanceTier;
        uint128 pendingExpansion;

        // === Time Tracking ===
        uint64 enrolledAt;
        uint64 firstDepositAt;
        uint64 lastDepositAt;
        uint64 lastClaimAt;
        uint64 lastSalaryAccrualTime;  // salary stream checkpoint
        uint64 amplifierWindowStart;    // 100-day window start
        uint64 amplifierWindowEnd;      // 100-day window end

        // === Daily Limits ===
        uint64 lastClaimDay;            // Day number (timestamp / 1 day)
        uint128 dailyClaimedUSD;        // USD claimed today
        uint128 workingEarnedUSD;      // cumulative working income paid (cap: 1x stake)

        // === Achievement Flags ===
        bool isEnrolled;
        bool isCapped;
        bool isGenesis;          // root user - special protected status
        uint8 currentPerformanceRank;   // 0-13 salary tier
        uint8 highestPerformanceRank;   // Highest ever achieved
        uint8 lifestyleAchieved;        // highest lifestyle tier achieved (0-10)
        uint8 highestExpansionTier;     // highest 3-leg expansion tier (0-13)

        // === Amplifier Status ===
        bool silverAchieved;
        bool goldAchieved;
        bool diamondAchieved;
        uint64 silverAchievedAt;
        uint64 goldAchievedAt;
        uint64 diamondAchievedAt;
        uint128 salaryCycleStartLegB;  // weaker-leg snapshot at maintenance cycle start
        uint64 salaryCycleStart;       // start of current 30-day maintenance cycle
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    enum AmplifierLevel {
        Base,       // 0.5% ROI, 3x cap
        Silver,     // 0.6% ROI, 4x cap
        Gold,       // 0.8% ROI, 5x cap
        Diamond     // 1.0% ROI, 5x cap
    }

    enum IncomeType {
        DailyROI,
        ProtocolBonus,      // Direct referral
        ProtocolStream,     // Level/depth
        ProtocolFlow,       // Upstream
        PerformanceTier,    // Salary
        Expansion,          // 3-leg
        Lifestyle           // Off-chain
    }

    enum SkipReason {
        UplineCapped,
        UplineNotQualified,
        MissingUpline,
        LevelLocked
    }


    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR CONFIG (Avoid stack too deep)
    // ═══════════════════════════════════════════════════════════════════════

    struct RewardGrant {
        uint8 tier;             // which performance-reward tier (1-13)
        uint128 totalUSD;       // full reward amount for this tier
        uint8 partsReleased;    // 0-4 (released in 4 installments)
        uint64 lastEventTime;   // achievement time, then last release time
    }

    struct Achiever {
        address user;
        uint8 tier;
        uint64 achievedAt;
    }

    struct VaultConfig {
        address pairAddress;
        address bibToken;
        address usdtToken;
        address router;
        address genesis;
        address protocolFee;
        address treasury;
        address coldTreasury;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event StakerEnrolled(
        address indexed staker,
        address indexed referrer,
        uint256 timestamp
    );

    event PositionCreated(
        address indexed staker,
        uint256 indexed positionId,
        uint128 depositUSDT,
        uint128 depositBB,
        uint128 lockedPrice,
        uint128 capUSD,
        uint64 unlockTime
    );

    event ROIAccrued(
        address indexed staker,
        uint256 indexed positionId,
        uint128 amountUSD,
        uint128 amountBB
    );

    event Claimed(
        address indexed staker,
        uint128 totalUSDClaimed,
        uint128 totalBBSent,
        uint128 deductionUSD
    );

    event ProtocolFlowToUpline(
        address indexed upline,
        address indexed source,
        uint256 level,
        uint128 amountUSD,
        uint128 amountBB
    );

    event ProtocolFlowToDAO(
        address indexed source,
        uint256 level,
        uint128 amountUSD,
        SkipReason reason
    );

    event AmplifierAchieved(
        address indexed staker,
        AmplifierLevel level,
        uint256 timestamp
    );

    event RankAchieved(
        address indexed staker,
        uint8 rank,
        uint256 timestamp
    );

    event ExpansionAchieved(
        address indexed staker,
        uint8 tier,
        uint128 rewardUSD
    );

    event ProtocolFeePaid(
        address indexed staker,
        uint128 amount
    );

    event LiquidityAdded(
        uint128 usdtAmount,
        uint128 bbAmount,
        uint128 lpTokens
    );

    event EmergencyPaused(address indexed by, uint256 timestamp);
    event EmergencyUnpaused(address indexed by, uint256 timestamp);
    event VaultRefilled(uint128 amount, uint256 timestamp);
    event AnomalyAutoPause(string reason, uint128 amount, uint256 timestamp);
    event AnomalyConfigUpdated(uint128 singleCeiling, uint16 spikeMult);
    event SalaryTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event ExpansionTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event LifestyleTierAchieved(address indexed user, uint8 tier, uint256 timestamp);
    event RewardQueued(address indexed user, uint8 tier, uint128 totalUSD);
    event RewardPartReleased(address indexed user, uint8 tier, uint8 part, uint128 amountUSD);
    event ClaimsToggled(bool enabled);
    event WalletClaimBlockedSet(address indexed wallet, bool blocked);
    event AddressBlockedSet(address indexed account, bool blocked);

    // ═══════════════════════════════════════════════════════════════════════
    // ANOMALY-MONITOR STATE (packed for storage; used via library delegatecall)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Packed claim-anomaly state. ~3 storage slots (was 7 individual
    ///         variables) — also enables passing as a storage ref to the
    ///         external AnomalyMonitor library so the vault stays under EIP-170.
    struct ClaimAnomalyData {
        uint128 claimedTodayUSD;          // running daily claim total
        uint128 avgDailyClaimUSD;         // 7-day running average
        uint128 claimHistorySum;          // sum used to compute the average
        uint128 singleClaimCeilingUSD;    // trigger 1 threshold (e.g. $5,000)
        uint64  claimAnomalyDay;          // current calendar day (since epoch / 1 day)
        uint16  claimHistoryDays;         // days counted in history (0..7)
        uint16  dailyClaimSpikeMult;      // trigger 2 multiplier (e.g. 3 → 3× avg)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error InvalidAmount();
    error AddressBlocked();
    error MaxDirectsReached();
    error InsufficientAllowance();
    error InsufficientUserBalance();
    error InvalidPair();
    error InvalidDecimals();
    error NotEOA();
    error SameBlockAction();
    error AlreadyEnrolled();
    error NotEnrolled();
    error ReferrerNotEnrolled();
    error SelfReferral();
    error CooldownActive();
    error EnrollGraceNotMet();
    error ReferrerGraceNotMet();
    error StakeGraceNotMet();
    error ClaimCooldownActive();
    error FirstClaimLocked();
    error PositionLocked();
    error DailyDepositLimitReached();
    error LifetimeStakeLimitReached();
    error MinDepositNotMet();
    error MaxDepositExceeded();
    error MaxWithdrawExceeded();
    error DailyClaimLimitReached();
    error CapReached();
    error LiquidityTooLow();
    error PriceImpactTooHigh();
    error TWAPDeviationTooHigh();
    error OracleStale();
    error InsufficientVaultBalance();
    error InsufficientGas();
    error EmergencyActive();
    error AlreadyPaused();
    error NotPaused();
    error LaunchAlreadyFinalized();
    error InvalidRefillAmount();
    error RefillTimelockActive();
    error UnauthorizedCaller();
    error ImpersonationDetected();
    error ChildContractDetected();
    error InvalidPositionId();
    error PositionNotActive();
    error NothingToClaim();
    error ProtocolFlowMismatch();
    error GenesisCannotStake();
    error GenesisProtected();
    error NoStakeToClaim();
    error RewardTimerActive();
    error NoRewardToClaim();
    error WalletClaimBlocked();
    error ClaimsDisabled();
    error BlockedSystemAddress();
    error ReferrerNotActive();
    error InvalidReferrer();
}
