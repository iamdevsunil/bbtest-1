// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";
import "../libraries/BBP_RewardLib.sol";
import "../libraries/BBP_PositionLib.sol";
import "../libraries/BBP_AmplifierLib.sol";

/**
 * @title IBigBullVault
 * @notice Minimal interface to read vault state
 */
interface IBigBullVault {
    function users(address) external view returns (
        address referrer, uint32 directsCount, uint32 activeDirectsCount,
        uint128 totalDepositUSD, uint128 totalEarnedUSD, uint128 totalClaimedUSD, uint128 currentCapUSD,
        uint128 totalDepositBB, uint128 totalClaimedBB, uint128 directBusinessUSD, uint128 teamVolumeUSD,
        uint128 strongestLegUSD, uint128 secondLegUSD, address strongestLegRoot, address secondLegRoot,
        uint128 pendingProtocolBonus, uint128 pendingProtocolStream, uint128 pendingProtocolFlow,
        uint128 pendingPerformanceTier, uint128 pendingExpansion,
        uint64 enrolledAt, uint64 firstDepositAt, uint64 lastDepositAt, uint64 lastClaimAt,
        uint64 lastSalaryAccrualTime, uint64 amplifierWindowStart, uint64 amplifierWindowEnd,
        uint64 lastClaimDay, uint128 dailyClaimedUSD, uint128 workingEarnedUSD,
        bool isEnrolled, bool isCapped, bool isGenesis,
        uint8 currentPerformanceRank, uint8 highestPerformanceRank, uint8 lifestyleAchieved, uint8 highestExpansionTier,
        bool silverAchieved, bool goldAchieved, bool diamondAchieved,
        uint64 silverAchievedAt, uint64 goldAchievedAt, uint64 diamondAchievedAt,
        uint128 salaryCycleStartLegB, uint64 salaryCycleStart
    );

    function getPositionCount(address user) external view returns (uint256);
    function rewardQueueHead(address user) external view returns (uint256);
    function rewardQueueLength(address user) external view returns (uint256);
    function rewardQueue(address user, uint256 index) external view returns (
        uint8 tier, uint128 totalUSD, uint8 partsReleased, uint64 lastEventTime
    );
    function lastRewardClaimAt(address user) external view returns (uint64);
    function getPosition(address user, uint256 id) external view returns (VaultTypes.Position memory);
    function getDirectsCount(address user) external view returns (uint256);
    function getDirect(address user, uint256 index) external view returns (address);

    function totalDepositedUSD() external view returns (uint128);
    function totalDistributedBB() external view returns (uint128);
    function totalUsers() external view returns (uint64);
    function totalActivePositions() external view returns (uint64);
    function totalStakesCreated() external view returns (uint64);
    function paused() external view returns (bool);
    function anomalyPaused() external view returns (bool);
    function launchFinalized() external view returns (bool);
    function getProtectedPriceView() external view returns (uint128);
    function getReserves() external view returns (uint128 bibReserve, uint128 usdtReserve);

    function salaryAchieverCount() external view returns (uint256);
    function expansionAchieverCount() external view returns (uint256);
    function lifestyleAchieverCount() external view returns (uint256);
    function salaryAchievers(uint256) external view returns (address user, uint8 tier, uint64 achievedAt);
    function expansionAchievers(uint256) external view returns (address user, uint8 tier, uint64 achievedAt);
    function lifestyleAchievers(uint256) external view returns (address user, uint8 tier, uint64 achievedAt);
}

/**
 * @title VaultReader
 * @notice Read-only data aggregator for BigBull V4 frontend
 * @dev Deploy AFTER the vault. Holds immutable vault reference.
 *      Provides paginated, aggregated, dashboard-ready views in single calls.
 *      ALL functions are view-only - cannot modify any state.
 *
 *  FRONTEND DISPLAY REQUIREMENTS COVERED:
 *   - All cooldowns / locks / limits with remaining time
 *   - Per-position claimable (USD + BB) with unlock countdown
 *   - User dashboard (one call)
 *   - Paginated positions / referrals
 *   - Protocol stats + DEX info
 *   - Amplifier progress + window countdown
 */
contract VaultReader {

    IBigBullVault public immutable vault;

    constructor(address vault_) {
        require(vault_ != address(0), "zero vault");
        vault = IBigBullVault(vault_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RESTRICTION DISPLAY (cooldowns, locks, limits - all with remaining time)
    // ═══════════════════════════════════════════════════════════════════════

    struct Restrictions {
        // Deposit-side
        uint64 depositCooldownRemaining;    // seconds until next deposit allowed
        uint16 depositsUsedToday;            // deposits made today
        uint16 maxDepositsPerDay;            // 50
        uint16 stakesUsed;                   // lifetime stakes used
        uint16 stakeLimit;                   // personal lifetime limit
        // Claim-side
        uint64 claimCooldownRemaining;       // seconds until next claim
        uint64 firstClaimLockRemaining;      // seconds until first claim unlocks
        uint128 dailyClaimUsedUSD;           // USD claimed today
        uint128 dailyClaimLimitUSD;          // 25% of currentCapUSD
        uint128 maxWithdrawPerClaimUSD;      // $1000
        // Amounts
        uint128 minDepositUSD;               // $10
        uint128 maxDepositUSD;               // $5000
    }

    /**
     * @notice Get all active restrictions for a user (frontend must display these)
     */
    function getRestrictions(address user) external view returns (Restrictions memory r) {
        _UserView memory u = _loadUser(user);
        uint64 nowT = uint64(block.timestamp);

        // Deposit cooldown (30s)
        if (u.lastDepositAt != 0) {
            uint64 unlock = u.lastDepositAt + VaultConstants.DEPOSIT_COOLDOWN;
            r.depositCooldownRemaining = nowT < unlock ? unlock - nowT : 0;
        }

        // Daily deposits
        uint64 today = nowT / uint64(VaultConstants.DAY);
        // depositsToday only valid if lastDepositDay == today; reader approximates
        r.maxDepositsPerDay = VaultConstants.MAX_DAILY_DEPOSITS;
        r.stakesUsed = uint16(vault.getPositionCount(user));
        r.stakeLimit = VaultConstants.MAX_STAKES;

        // Claim cooldown (2 min)
        if (u.lastClaimAt != 0) {
            uint64 unlock = u.lastClaimAt + VaultConstants.CLAIM_COOLDOWN;
            r.claimCooldownRemaining = nowT < unlock ? unlock - nowT : 0;
        }

        // First claim lock (24h after first deposit)
        if (u.firstDepositAt != 0) {
            uint64 unlock = u.firstDepositAt + VaultConstants.FIRST_CLAIM_LOCK;
            r.firstClaimLockRemaining = nowT < unlock ? unlock - nowT : 0;
        }

        // Daily claim limit (25% of cap)
        r.dailyClaimLimitUSD = uint128(
            (uint256(u.currentCapUSD) * VaultConstants.DAILY_CLAIM_CAP_BP) /
            VaultConstants.PERC_DIVIDER
        );
        if (u.lastClaimDay == today) {
            r.dailyClaimUsedUSD = u.dailyClaimedUSD;
        }

        r.maxWithdrawPerClaimUSD = VaultConstants.MAX_WITHDRAW_USD;
        r.minDepositUSD = VaultConstants.MIN_DEPOSIT;
        r.maxDepositUSD = VaultConstants.MAX_DEPOSIT;

        return r;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // USER DASHBOARD (one-call snapshot)
    // ═══════════════════════════════════════════════════════════════════════

    struct Dashboard {
        bool isEnrolled;
        bool isCapped;
        address referrer;
        uint32 directsCount;
        uint128 totalDepositUSD;
        uint128 totalEarnedUSD;
        uint128 totalClaimedUSD;
        uint128 currentCapUSD;
        uint128 totalDepositBB;
        uint128 totalClaimedBB;
        uint128 teamVolumeUSD;
        uint128 strongestLegUSD;
        uint128 secondLegUSD;
        uint8 amplifierLevel;        // 0=base,1=silver,2=gold,3=diamond
        uint8 performanceRank;
        uint64 amplifierWindowRemaining; // seconds left in 100-day window
        uint256 positionCount;
        uint128 totalClaimableUSD;   // sum across unlocked positions
        uint128 totalClaimableBB;
        uint128 totalPendingUSD;     // pending team income
    }

    function getDashboard(address user) external view returns (Dashboard memory d) {
        _UserView memory u = _loadUser(user);
        uint64 nowT = uint64(block.timestamp);

        d.isEnrolled = u.isEnrolled;
        d.isCapped = u.isCapped;
        d.referrer = u.referrer;
        d.directsCount = u.directsCount;
        d.totalDepositUSD = u.totalDepositUSD;
        d.totalEarnedUSD = u.totalEarnedUSD;
        d.totalClaimedUSD = u.totalClaimedUSD;
        d.currentCapUSD = u.currentCapUSD;
        d.totalDepositBB = u.totalDepositBB;
        d.totalClaimedBB = u.totalClaimedBB;
        d.teamVolumeUSD = u.teamVolumeUSD;
        d.strongestLegUSD = u.strongestLegUSD;
        d.secondLegUSD = u.secondLegUSD;
        d.performanceRank = u.currentPerformanceRank;

        // Amplifier level
        if (u.diamondAchieved) d.amplifierLevel = 3;
        else if (u.goldAchieved) d.amplifierLevel = 2;
        else if (u.silverAchieved) d.amplifierLevel = 1;
        else d.amplifierLevel = 0;

        // Amplifier window remaining
        if (u.firstDepositAt != 0) {
            uint64 end = u.firstDepositAt + VaultConstants.AMPLIFIER_WINDOW;
            d.amplifierWindowRemaining = nowT < end ? end - nowT : 0;
        }

        // Positions + live claimable
        uint256 count = vault.getPositionCount(user);
        d.positionCount = count;

        (uint128 cUSD, uint128 cBB) = _sumClaimable(user, count, d.amplifierLevel, nowT);
        d.totalClaimableUSD = cUSD;
        d.totalClaimableBB = cBB;

        d.totalPendingUSD = u.pendingProtocolBonus + u.pendingProtocolStream +
                            u.pendingProtocolFlow + u.pendingPerformanceTier +
                            u.pendingExpansion;

        return d;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // POSITIONS (paginated, newest-first)
    // ═══════════════════════════════════════════════════════════════════════

    struct PositionView {
        uint256 positionId;
        uint128 depositUSDT;
        uint128 depositBB;
        uint128 lockedPrice;
        uint128 capUSD;
        uint128 earnedUSD;
        uint128 claimedUSD;
        uint128 earnedBB;
        uint128 claimedBB;
        uint128 liveClaimableUSD;
        uint128 liveClaimableBB;
        uint64 stakeTime;
        uint64 unlockTime;
        uint64 unlockRemaining;     // seconds until 24h unlock
        uint8 amplifierLevel;
        bool active;
        bool capped;                // ROI cap is currently full
        bool isClosed;              // PERMANENTLY closed (once isClosed is true, this
                                    // position never reopens — even after booster cap-mult upgrades.
                                    // Closed positions do not accrue further ROI.)
    }

    /**
     * @notice Get paginated positions (newest first)
     * @param user User address
     * @param offset Starting offset (0 = newest)
     * @param limit Max results (recommend <= 20)
     */
    function getPositions(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (PositionView[] memory results, uint256 total) {
        total = vault.getPositionCount(user);
        if (offset >= total || limit == 0) {
            return (new PositionView[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 n = remaining < limit ? remaining : limit;
        results = new PositionView[](n);

        _UserView memory u = _loadUser(user);
        uint8 ampLevel = _ampLevel(u);
        uint64 nowT = uint64(block.timestamp);

        // Newest-first: index from (total-1-offset) downward
        for (uint256 i = 0; i < n; ) {
            uint256 idx = total - 1 - offset - i;
            VaultTypes.Position memory p = vault.getPosition(user, idx);

            PositionView memory pv;
            pv.positionId = idx;
            pv.depositUSDT = p.depositUSDT;
            pv.depositBB = p.depositBB;
            pv.lockedPrice = p.lockedPrice;
            pv.capUSD = p.capUSD;
            pv.earnedUSD = p.earnedUSD;
            pv.claimedUSD = p.claimedUSD;
            pv.earnedBB = p.earnedBB;
            pv.claimedBB = p.claimedBB;
            pv.stakeTime = p.stakeTime;
            pv.unlockTime = p.unlockTime;
            pv.unlockRemaining = nowT < p.unlockTime ? p.unlockTime - nowT : 0;
            pv.amplifierLevel = p.amplifierLevel;
            pv.active = p.active;
            pv.capped = p.capped;
            pv.isClosed = p.isClosed;

            // Live claimable (with accrued ROI)
            (uint128 liveUSD, uint128 liveBB, uint128 claimUSD, uint128 claimBB) =
                PositionLib.getLiveEarnings(p, ampLevel, nowT);
            // suppress unused warnings
            liveUSD; liveBB;
            pv.liveClaimableUSD = claimUSD;
            pv.liveClaimableBB = claimBB;

            results[i] = pv;
            unchecked { ++i; }
        }

        return (results, total);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REFERRALS (paginated)
    // ═══════════════════════════════════════════════════════════════════════

    function getReferrals(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory results, uint256 total) {
        total = vault.getDirectsCount(user);
        if (offset >= total || limit == 0) {
            return (new address[](0), total);
        }
        uint256 remaining = total - offset;
        uint256 n = remaining < limit ? remaining : limit;
        results = new address[](n);
        for (uint256 i = 0; i < n; ) {
            results[i] = vault.getDirect(user, offset + i);
            unchecked { ++i; }
        }
        return (results, total);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL STATS + DEX INFO
    // ═══════════════════════════════════════════════════════════════════════

    struct ProtocolStats {
        uint128 totalDepositedUSD;
        uint128 totalDistributedBB;
        uint64 totalUsers;
        uint64 totalActivePositions;
        uint64 totalStakesCreated;
        bool paused;
        bool anomalyPaused;
        bool launchFinalized;
        uint128 bibReserve;
        uint128 usdtReserve;
        uint128 currentPrice;       // protected price (max spot,twap)
    }

    function getProtocolStats() external view returns (ProtocolStats memory s) {
        s.totalDepositedUSD = vault.totalDepositedUSD();
        s.totalDistributedBB = vault.totalDistributedBB();
        s.totalUsers = vault.totalUsers();
        s.totalActivePositions = vault.totalActivePositions();
        s.totalStakesCreated = vault.totalStakesCreated();
        s.paused = vault.paused();
        s.anomalyPaused = vault.anomalyPaused();
        s.launchFinalized = vault.launchFinalized();

        try vault.getReserves() returns (uint128 b, uint128 q) {
            s.bibReserve = b;
            s.usdtReserve = q;
        } catch {}

        try vault.getProtectedPriceView() returns (uint128 p) {
            s.currentPrice = p;
        } catch {}

        return s;
    }

    /**
     * @notice Salary maintenance status — the 10% weaker-leg monthly rule.
     * @dev Frontend shows whether the user is currently eligible for daily salary
     *      this cycle, how much fresh weaker-leg business they have vs need, and
     *      when the cycle resets.
     */
    function getSalaryMaintenance(address user) external view returns (
        bool compliant,
        uint128 freshWeakerLegUSD,   // fresh weaker-leg business this cycle
        uint128 requiredUSD,         // 10% of rank's weaker-leg target
        uint64 cycleEndsAt,          // when the current 30-day cycle resets
        uint8 rank
    ) {
        _UserView memory u = _loadUser(user);
        rank = u.highestPerformanceRank;
        if (rank == 0) return (false, 0, 0, 0, 0);

        uint128 legB = u.teamVolumeUSD > u.strongestLegUSD
            ? u.teamVolumeUSD - u.strongestLegUSD
            : 0;

        // Mirror the on-chain cycle roll for an accurate read
        uint64 cycleStart = u.salaryCycleStart;
        uint128 baseline = u.salaryCycleStartLegB;
        if (cycleStart == 0) {
            cycleStart = uint64(block.timestamp);
            baseline = legB;
        } else if (block.timestamp >= cycleStart + uint64(VaultConstants.SALARY_CYCLE)) {
            // a reset is due; fresh business resets to 0 against current legB
            baseline = legB;
            uint64 cycles = (uint64(block.timestamp) - cycleStart) / uint64(VaultConstants.SALARY_CYCLE);
            cycleStart += cycles * uint64(VaultConstants.SALARY_CYCLE);
        }

        ( , uint128 legBTarget, ) = VaultConstants.getSalaryTier(rank);
        requiredUSD = uint128(
            (uint256(legBTarget) * VaultConstants.SALARY_MAINTENANCE_BP) / VaultConstants.PERC_DIVIDER
        );
        freshWeakerLegUSD = legB > baseline ? legB - baseline : 0;
        compliant = freshWeakerLegUSD >= requiredUSD;
        cycleEndsAt = cycleStart + uint64(VaultConstants.SALARY_CYCLE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BOOSTER STATUS (frontend: 100-day window + amplifier level)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Booster / amplifier status for a user.
     * @dev Booster must be achieved within 100 days of first deposit (once per
     *      lifetime). Each level raises ROI cap + daily rate.
     */
    function getBoosterStatus(address user) external view returns (
        uint8 currentLevel,       // 0 base, 1 silver, 2 gold, 3 diamond
        uint16 dailyRateBP,       // current daily ROI rate (bp)
        uint8 roiCapMult,         // current ROI cap multiplier (2/3/4)
        uint8 totalCapMult,       // current total cap multiplier (3/4/5)
        bool inWindow,            // still inside the 100-day window?
        uint64 windowEndsAt,      // timestamp the window closes
        uint8 salaryRank,         // highest salary rank (drives booster)
        bool silver, bool gold, bool diamond
    ) {
        _UserView memory u = _loadUser(user);
        currentLevel = u.diamondAchieved ? 3 : u.goldAchieved ? 2 : u.silverAchieved ? 1 : 0;
        dailyRateBP =
            currentLevel == 3 ? VaultConstants.DIAMOND_RATE_BP :
            currentLevel == 2 ? VaultConstants.GOLD_RATE_BP :
            currentLevel == 1 ? VaultConstants.SILVER_RATE_BP :
                                VaultConstants.BASE_RATE_BP;
        roiCapMult =
            currentLevel >= 2 ? 4 :
            currentLevel == 1 ? 3 : 2;
        totalCapMult = roiCapMult + 1;
        windowEndsAt = u.firstDepositAt == 0
            ? 0
            : u.firstDepositAt + uint64(VaultConstants.AMPLIFIER_WINDOW);
        inWindow = u.firstDepositAt != 0 && block.timestamp <= windowEndsAt;
        salaryRank = u.highestPerformanceRank;
        silver = u.silverAchieved;
        gold = u.goldAchieved;
        diamond = u.diamondAchieved;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // REWARD CLAIM STATUS (frontend: claim button + 6h timer)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Status of the currently-processing Performance Reward grant.
     * @dev Frontend uses this to render the claim button + countdown. Each grant
     *      releases in 4 parts, 6h apart.
     */
    function getRewardClaimStatus(address user) external view returns (
        bool hasReward,            // is there a grant waiting?
        uint8 tier,                // tier of the head grant
        uint128 totalUSD,          // full reward amount for the head grant (paid in one shot)
        bool claimableNow,         // can claimReward() be called right now?
        uint64 nextHoldUnlockTime, // when the head grant's 24h hold elapses
        uint64 nextCooldownEnds,   // when the separate REWARD_CLAIM_COOLDOWN (24h) elapses
        uint256 pendingGrants      // grants still queued (incl. head)
    ) {
        uint256 head = vault.rewardQueueHead(user);
        uint256 len = vault.rewardQueueLength(user);
        pendingGrants = len > head ? len - head : 0;
        if (pendingGrants == 0) {
            return (false, 0, 0, false, 0, 0, 0);
        }
        uint64 lastEvent;
        (tier, totalUSD, , lastEvent) = vault.rewardQueue(user, head);
        hasReward = true;

        // Single-release model: the FULL totalUSD moves into pendingExpansion in one call,
        // once both timers have elapsed.
        // Timer 1: 24h hold from the achievement (or last release event on this grant).
        // Timer 2: 24h cooldown since the user's previous claimReward() (separate from
        //          the regular claim() cooldown — independent timers).
        nextHoldUnlockTime = lastEvent + 24 hours; // REWARD_HOLD_DELAY
        uint64 lastRwdAt = vault.lastRewardClaimAt(user);
        nextCooldownEnds = lastRwdAt == 0 ? 0 : lastRwdAt + 24 hours; // REWARD_CLAIM_COOLDOWN
        uint64 nowT = uint64(block.timestamp);
        claimableNow = nowT >= nextHoldUnlockTime && nowT >= nextCooldownEnds;
    }

    /**
     * @notice All queued reward grants for a user (newest-first), for history UI.
     */
    function getRewardQueue(address user, uint256 offset, uint256 limit)
        external view returns (VaultTypes.RewardGrant[] memory grants)
    {
        uint256 len = vault.rewardQueueLength(user);
        if (offset >= len) return new VaultTypes.RewardGrant[](0);
        uint256 end = len - offset;
        uint256 start = end > limit ? end - limit : 0;
        grants = new VaultTypes.RewardGrant[](end - start);
        uint256 j = 0;
        for (uint256 i = end; i > start; ) {
            (uint8 t, uint128 amt, uint8 parts, uint64 le) = vault.rewardQueue(user, i - 1);
            grants[j] = VaultTypes.RewardGrant(t, amt, parts, le);
            unchecked { ++j; --i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 50-LEVEL QUALIFICATION (frontend: each level complete or not)
    // ═══════════════════════════════════════════════════════════════════════

    struct LevelRow {
        uint8 level;
        uint8 requiredDirects;
        bool directsMet;
        uint128 requiredSelfStakeUSD;  // $25 × level
        bool selfStakeMet;
        uint16 incomeBP;               // level income basis points
        bool unlocked;                 // both conditions satisfied
    }

    /**
     * @notice Full 50-level qualification status for a user.
     * @dev For each level: required active directs vs held, required self stake
     *      ($25 × level) vs held, the income %, and whether the level is unlocked.
     */
    function getLevelQualification(address user) external view returns (
        uint32 activeDirects,
        uint128 selfStakeUSD,
        uint8 levelsUnlocked,
        LevelRow[] memory rows
    ) {
        _UserView memory u = _loadUser(user);
        activeDirects = u.activeDirectsCount;
        selfStakeUSD = u.totalDepositUSD;

        rows = new LevelRow[](50);
        for (uint8 l = 1; l <= 50; ) {
            uint8 reqD = VaultConstants.getRequiredDirects(l);
            uint128 reqStake = VaultConstants.getSelfTopupRequired(l);
            bool dMet = activeDirects >= reqD;
            bool sMet = selfStakeUSD >= reqStake;
            bool unlocked = dMet && sMet;
            if (unlocked) levelsUnlocked = l;
            rows[l-1] = LevelRow(
                l, reqD, dMet, reqStake, sMet,
                VaultConstants.getLevelIncomeBP(l), unlocked
            );
            unchecked { ++l; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SALARY & REWARD PROGRESS (per-user 13-tier tables for frontend)
    // ═══════════════════════════════════════════════════════════════════════

    struct TierRow {
        uint8 tier;
        string rankName;
        uint128 reqA;        // Leg A / Leg 1 requirement (USD)
        uint128 reqB;        // Leg B / Leg 2 requirement (USD)
        uint128 reqC;        // Leg 3 requirement (USD) — 0 for salary
        uint128 rewardUSD;   // daily bonus (salary) or total reward (rewards)
        bool achieved;
    }

    /**
     * @notice Performance Salary Bonus progress for a user (all 13 tiers):
     *         strongest leg, all-other legs, current tier, pending salary, and
     *         the full 13-tier table with requirements and achieved flags.
     */
    function getSalaryProgress(address user) external view returns (
        uint128 legA,
        uint128 legB,
        uint8 currentTier,
        uint128 pendingSalaryUSD,
        TierRow[] memory rows
    ) {
        _UserView memory u = _loadUser(user);
        legA = u.strongestLegUSD;
        legB = u.teamVolumeUSD > legA ? u.teamVolumeUSD - legA : 0;
        currentTier = u.highestPerformanceRank;

        // Buffered + live-accrued salary
        pendingSalaryUSD = u.pendingPerformanceTier;
        if (currentTier > 0 && u.lastSalaryAccrualTime != 0) {
            (, , uint128 dailyBonus) = VaultConstants.getSalaryTier(currentTier);
            uint64 nowT = uint64(block.timestamp);
            if (nowT > u.lastSalaryAccrualTime) {
                uint256 elapsed = nowT - u.lastSalaryAccrualTime;
                pendingSalaryUSD += uint128((uint256(dailyBonus) * elapsed) / VaultConstants.DAY);
            }
        }

        rows = new TierRow[](13);
        for (uint8 t = 1; t <= 13; ) {
            (uint128 a, uint128 b, uint128 bonus) = VaultConstants.getSalaryTier(t);
            rows[t-1] = TierRow(t, _salaryRankName(t), a, b, 0, bonus, t <= currentTier);
            unchecked { ++t; }
        }
    }

    /**
     * @notice Performance Rewards (3-leg) progress for a user (all 13 tiers):
     *         leg1/leg2/leg3 volumes, current tier, pending one-time rewards, and
     *         the full 13-tier table with requirements and achieved flags.
     */
    function getRewardProgress(address user) external view returns (
        uint128 leg1,
        uint128 leg2,
        uint128 leg3,
        uint8 currentTier,
        uint128 pendingRewardUSD,
        TierRow[] memory rows
    ) {
        _UserView memory u = _loadUser(user);
        leg1 = u.strongestLegUSD;
        leg2 = u.secondLegUSD;
        uint128 other = u.teamVolumeUSD > leg1 ? u.teamVolumeUSD - leg1 : 0;
        leg3 = other > leg2 ? other - leg2 : 0;
        currentTier = u.highestExpansionTier;
        pendingRewardUSD = u.pendingExpansion;

        rows = new TierRow[](13);
        for (uint8 t = 1; t <= 13; ) {
            (uint128 a, uint128 b, uint128 c, uint128 reward) = VaultConstants.getExpansionTier(t);
            rows[t-1] = TierRow(t, _salaryRankName(t), a, b, c, reward, t <= currentTier);
            unchecked { ++t; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACHIEVER REGISTRIES (latest-first, unlimited pagination)
    // ═══════════════════════════════════════════════════════════════════════

    struct AchieverView {
        address user;
        uint8 tier;
        string rankName;
        string rewardName;
        uint64 achievedAt;
    }

    /**
     * @notice Dream Lifestyle & Travel Rewards achievers — newest first.
     * @param offset 0 = most recent achiever
     * @param limit  page size (use a large number for "no limit" feel)
     */
    function getLifestyleAchievers(uint256 offset, uint256 limit)
        external view returns (AchieverView[] memory results, uint256 total)
    {
        total = vault.lifestyleAchieverCount();
        if (offset >= total || limit == 0) return (new AchieverView[](0), total);
        uint256 n = (total - offset) < limit ? (total - offset) : limit;
        results = new AchieverView[](n);
        for (uint256 i = 0; i < n; ) {
            uint256 idx = total - 1 - offset - i;   // newest first
            (address u, uint8 t, uint64 at) = vault.lifestyleAchievers(idx);
            results[i] = AchieverView(u, t, _lifestyleRankName(t), _lifestyleReward(t), at);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Performance Salary Bonus achievers — newest first.
     */
    function getSalaryAchievers(uint256 offset, uint256 limit)
        external view returns (AchieverView[] memory results, uint256 total)
    {
        total = vault.salaryAchieverCount();
        if (offset >= total || limit == 0) return (new AchieverView[](0), total);
        uint256 n = (total - offset) < limit ? (total - offset) : limit;
        results = new AchieverView[](n);
        for (uint256 i = 0; i < n; ) {
            uint256 idx = total - 1 - offset - i;
            (address u, uint8 t, uint64 at) = vault.salaryAchievers(idx);
            results[i] = AchieverView(u, t, _salaryRankName(t), "", at);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Performance Rewards (3-leg) achievers — newest first.
     */
    function getExpansionAchievers(uint256 offset, uint256 limit)
        external view returns (AchieverView[] memory results, uint256 total)
    {
        total = vault.expansionAchieverCount();
        if (offset >= total || limit == 0) return (new AchieverView[](0), total);
        uint256 n = (total - offset) < limit ? (total - offset) : limit;
        results = new AchieverView[](n);
        for (uint256 i = 0; i < n; ) {
            uint256 idx = total - 1 - offset - i;
            (address u, uint8 t, uint64 at) = vault.expansionAchievers(idx);
            results[i] = AchieverView(u, t, _salaryRankName(t), "", at);
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RANK NAMING (BigBull plan naming convention)
    // ═══════════════════════════════════════════════════════════════════════

    function _salaryRankName(uint8 tier) internal pure returns (string memory) {
        if (tier == 1)  return "BB-Starter";
        if (tier == 2)  return "BB-Achiever";
        if (tier == 3)  return "BB-Builder";
        if (tier == 4)  return "BB-Leader";
        if (tier == 5)  return "BB-Captain";
        if (tier == 6)  return "BB-Champion";
        if (tier == 7)  return "BB-Ambassador";
        if (tier == 8)  return "BB-Director";
        if (tier == 9)  return "BB-Elite Director";
        if (tier == 10) return "BB-Crown Director";
        if (tier == 11) return "BB-Global Leader";
        if (tier == 12) return "BB-Royal Emperor";
        if (tier == 13) return "Big Bull Legend";
        return "";
    }

    function _lifestyleRankName(uint8 tier) internal pure returns (string memory) {
        if (tier == 1)  return "BB-Leader";
        if (tier == 2)  return "BB-Captain";
        if (tier == 3)  return "BB-Champion";
        if (tier == 4)  return "BB-Ambassador";
        if (tier == 5)  return "BB-Director";
        if (tier == 6)  return "BB-Elite Director";
        if (tier == 7)  return "BB-Crown Director";
        if (tier == 8)  return "BB-Global Leader";
        if (tier == 9)  return "BB-Royal Emperor";
        if (tier == 10) return "Big Bull Legend";
        return "";
    }

    function _lifestyleReward(uint8 tier) internal pure returns (string memory) {
        if (tier == 1)  return "Thailand Tour";
        if (tier == 2)  return "Dubai Tour";
        if (tier == 3)  return "Singapore Couple Tour";
        if (tier == 4)  return "Maldives Couple Tour";
        if (tier == 5)  return "Europe Tour (4 country couple)";
        if (tier == 6)  return "World Tour (9 country couple)";
        if (tier == 7)  return "Mercedes Benz ($100,000)";
        if (tier == 8)  return "Land Rover ($200,000)";
        if (tier == 9)  return "Ferrari";
        if (tier == 10) return "Villa in Dubai ($1 million)";
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    struct _UserView {
        address referrer; uint32 directsCount; uint32 activeDirectsCount;
        uint128 totalDepositUSD; uint128 totalEarnedUSD; uint128 totalClaimedUSD; uint128 currentCapUSD;
        uint128 totalDepositBB; uint128 totalClaimedBB; uint128 teamVolumeUSD;
        uint128 strongestLegUSD; uint128 secondLegUSD;
        uint128 pendingProtocolBonus; uint128 pendingProtocolStream; uint128 pendingProtocolFlow;
        uint128 pendingPerformanceTier; uint128 pendingExpansion;
        uint64 firstDepositAt; uint64 lastDepositAt; uint64 lastClaimAt; uint64 lastSalaryAccrualTime;
        uint64 lastClaimDay; uint128 dailyClaimedUSD;
        bool isEnrolled; bool isCapped; bool isGenesis;
        uint8 currentPerformanceRank; uint8 highestPerformanceRank; uint8 highestExpansionTier; uint8 lifestyleAchieved;
        bool silverAchieved; bool goldAchieved; bool diamondAchieved;
        uint128 salaryCycleStartLegB; uint64 salaryCycleStart;
    }

    function _loadUser(address user) internal view returns (_UserView memory v) {
        (
            v.referrer, v.directsCount, v.activeDirectsCount,
            v.totalDepositUSD, v.totalEarnedUSD, v.totalClaimedUSD, v.currentCapUSD,
            v.totalDepositBB, v.totalClaimedBB, /*directBusinessUSD*/, v.teamVolumeUSD,
            v.strongestLegUSD, v.secondLegUSD, /*strongestLegRoot*/, /*secondLegRoot*/,
            v.pendingProtocolBonus, v.pendingProtocolStream, v.pendingProtocolFlow,
            v.pendingPerformanceTier, v.pendingExpansion,
            /*enrolledAt*/, v.firstDepositAt, v.lastDepositAt, v.lastClaimAt,
            v.lastSalaryAccrualTime, /*ampWindowStart*/, /*ampWindowEnd*/,
            v.lastClaimDay, v.dailyClaimedUSD, /*workingEarnedUSD*/,
            v.isEnrolled, v.isCapped, v.isGenesis,
            v.currentPerformanceRank, v.highestPerformanceRank, v.lifestyleAchieved, v.highestExpansionTier,
            v.silverAchieved, v.goldAchieved, v.diamondAchieved,
            /*silverAt*/, /*goldAt*/, /*diamondAt*/,
            v.salaryCycleStartLegB, v.salaryCycleStart
        ) = vault.users(user);
    }

    function _ampLevel(_UserView memory u) internal pure returns (uint8) {
        if (u.diamondAchieved) return 3;
        if (u.goldAchieved) return 2;
        if (u.silverAchieved) return 1;
        return 0;
    }

    function _sumClaimable(
        address user,
        uint256 count,
        uint8 ampLevel,
        uint64 nowT
    ) internal view returns (uint128 totalUSD, uint128 totalBB) {
        for (uint256 i = 0; i < count; ) {
            VaultTypes.Position memory p = vault.getPosition(user, i);
            if (p.active && nowT >= p.unlockTime) {
                (, , uint128 cUSD, uint128 cBB) =
                    PositionLib.getLiveEarnings(p, ampLevel, nowT);
                totalUSD += cUSD;
                totalBB += cBB;
            }
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKE SUMMARY + OPEN/CLOSED FILTERED VIEWS (frontend dashboard)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice High-level summary of a user's stakes — open vs closed counts plus
    ///         lifetime aggregates. One call gives the dashboard everything it needs
    ///         to render a "Stakes" tab without iterating individual positions.
    function getStakeSummary(address user) external view returns (
        uint256 totalPositions,
        uint256 openCount,
        uint256 closedCount,
        uint128 totalDepositUSD,
        uint128 totalEarnedROIUSD,
        uint128 totalClaimedUSD,
        uint128 totalROICapRemaining
    ) {
        totalPositions = vault.getPositionCount(user);
        for (uint256 i = 0; i < totalPositions; ) {
            VaultTypes.Position memory p = vault.getPosition(user, i);
            if (p.isClosed) {
                closedCount++;
            } else {
                openCount++;
                if (p.capUSD > p.earnedUSD) {
                    totalROICapRemaining += (p.capUSD - p.earnedUSD);
                }
            }
            totalDepositUSD    += p.depositUSDT;
            totalEarnedROIUSD  += p.earnedUSD;
            totalClaimedUSD    += p.claimedUSD;
            unchecked { ++i; }
        }
    }

    /// @notice Paginated view of OPEN positions only (newest-first). Use this when the
    ///         user wants to see currently-accruing stakes on the dashboard.
    /// @dev    Implementation: walks all positions newest-first, skipping closed ones,
    ///         collects up to `limit` opens after skipping `offset` matches.
    /// @param  user    The user to query.
    /// @param  offset  Number of open positions to skip (0 = newest open).
    /// @param  limit   Max open positions to return.
    /// @return results The matched open PositionView slice.
    /// @return totalOpen Total number of open positions for the user (for UI paging).
    function getOpenPositions(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (PositionView[] memory results, uint256 totalOpen) {
        uint256 totalPos = vault.getPositionCount(user);
        // First pass: count opens (also needed for UI total)
        for (uint256 i = 0; i < totalPos; ) {
            if (!vault.getPosition(user, i).isClosed) totalOpen++;
            unchecked { ++i; }
        }
        if (offset >= totalOpen || limit == 0) {
            return (new PositionView[](0), totalOpen);
        }
        uint256 remaining = totalOpen - offset;
        uint256 n = remaining < limit ? remaining : limit;
        results = new PositionView[](n);

        _UserView memory u = _loadUser(user);
        uint8 ampLevel = _ampLevel(u);
        uint64 nowT = uint64(block.timestamp);

        // Walk newest-first, skip `offset` opens, then fill `n` results.
        uint256 seen = 0;
        uint256 outIdx = 0;
        for (uint256 i = totalPos; i > 0 && outIdx < n; ) {
            uint256 idx = i - 1;
            VaultTypes.Position memory p = vault.getPosition(user, idx);
            if (!p.isClosed) {
                if (seen >= offset) {
                    results[outIdx++] = _buildPositionView(idx, p, ampLevel, nowT);
                }
                seen++;
            }
            unchecked { --i; }
        }
    }

    /// @notice Paginated view of CLOSED positions only (newest-first). Useful for a
    ///         "history" or "completed stakes" tab on the dashboard.
    function getClosedPositions(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (PositionView[] memory results, uint256 totalClosed) {
        uint256 totalPos = vault.getPositionCount(user);
        for (uint256 i = 0; i < totalPos; ) {
            if (vault.getPosition(user, i).isClosed) totalClosed++;
            unchecked { ++i; }
        }
        if (offset >= totalClosed || limit == 0) {
            return (new PositionView[](0), totalClosed);
        }
        uint256 remaining = totalClosed - offset;
        uint256 n = remaining < limit ? remaining : limit;
        results = new PositionView[](n);

        _UserView memory u = _loadUser(user);
        uint8 ampLevel = _ampLevel(u);
        uint64 nowT = uint64(block.timestamp);

        uint256 seen = 0;
        uint256 outIdx = 0;
        for (uint256 i = totalPos; i > 0 && outIdx < n; ) {
            uint256 idx = i - 1;
            VaultTypes.Position memory p = vault.getPosition(user, idx);
            if (p.isClosed) {
                if (seen >= offset) {
                    results[outIdx++] = _buildPositionView(idx, p, ampLevel, nowT);
                }
                seen++;
            }
            unchecked { --i; }
        }
    }

    /// @dev Builds a PositionView from a raw Position. Shared by getOpenPositions /
    ///      getClosedPositions to avoid code duplication.
    function _buildPositionView(
        uint256 idx,
        VaultTypes.Position memory p,
        uint8 ampLevel,
        uint64 nowT
    ) internal pure returns (PositionView memory pv) {
        pv.positionId      = idx;
        pv.depositUSDT     = p.depositUSDT;
        pv.depositBB       = p.depositBB;
        pv.lockedPrice     = p.lockedPrice;
        pv.capUSD          = p.capUSD;
        pv.earnedUSD       = p.earnedUSD;
        pv.claimedUSD      = p.claimedUSD;
        pv.earnedBB        = p.earnedBB;
        pv.claimedBB       = p.claimedBB;
        pv.stakeTime       = p.stakeTime;
        pv.unlockTime      = p.unlockTime;
        pv.unlockRemaining = nowT >= p.unlockTime ? 0 : p.unlockTime - nowT;
        pv.amplifierLevel  = p.amplifierLevel;
        pv.active          = p.active;
        pv.capped          = p.capped;
        pv.isClosed        = p.isClosed;
        if (p.active && nowT >= p.unlockTime && !p.isClosed) {
            (, , uint128 cUSD, uint128 cBB) =
                PositionLib.getLiveEarnings(p, ampLevel, nowT);
            pv.liveClaimableUSD = cUSD;
            pv.liveClaimableBB  = cBB;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TEAM TREE — Direct referrals with their summary stats (paginated)
    // ═══════════════════════════════════════════════════════════════════════

    struct DirectInfo {
        address user;
        uint128 totalDepositUSD;
        uint128 totalEarnedUSD;
        uint128 totalClaimedUSD;
        uint32  directsCount;
        uint128 teamVolumeUSD;
        uint64  firstDepositAt;
        uint64  lastDepositAt;
        bool    isCapped;
        bool    isEnrolled;
        uint8   performanceRank;
    }

    /**
     * @notice Get directs of `user` (paginated) along with their key stats.
     * @param user   Account whose direct referrals are queried
     * @param offset Starting index in their directs list
     * @param limit  Max directs to return
     * @return list  Array of DirectInfo
     * @return total Total directs count of `user`
     */
    function getDirectReferralsDetailed(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (DirectInfo[] memory list, uint256 total) {
        total = vault.getDirectsCount(user);
        if (offset >= total || limit == 0) {
            return (new DirectInfo[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        list = new DirectInfo[](size);

        for (uint256 i = 0; i < size; i++) {
            address d = vault.getDirect(user, offset + i);
            _UserView memory uv = _loadUser(d);
            DirectInfo memory di;
            di.user = d;
            di.totalDepositUSD = uv.totalDepositUSD;
            di.totalEarnedUSD = uv.totalEarnedUSD;
            di.totalClaimedUSD = uv.totalClaimedUSD;
            di.directsCount = uv.directsCount;
            di.teamVolumeUSD = uv.teamVolumeUSD;
            di.firstDepositAt = uv.firstDepositAt;
            di.lastDepositAt = uv.lastDepositAt;
            di.isCapped = uv.isCapped;
            di.isEnrolled = uv.isEnrolled;
            di.performanceRank = uv.currentPerformanceRank;
            list[i] = di;
        }
    }

    /**
     * @notice Quick check whether an address is enrolled in the protocol.
     *         Useful for frontend ref-validation without loading full struct.
     */
    function isEnrolled(address user) external view returns (bool) {
        _UserView memory v = _loadUser(user);
        return v.isEnrolled;
    }

    /**
     * @notice Get user's referrer (sponsor) address.
     */
    function getReferrer(address user) external view returns (address) {
        _UserView memory v = _loadUser(user);
        return v.referrer;
    }

    /**
     * @notice Full per-direct branch business volume.
     */
    function getBranchVolume(address user, address direct) external view returns (uint128) {
        return IBranchVolume(address(vault)).legBusinessUSD(user, direct);
    }
}

interface IBranchVolume {
    function legBusinessUSD(address, address) external view returns (uint128);
}
