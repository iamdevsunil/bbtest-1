// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./BBP_Storage.sol";
import "./libraries/BBP_RewardLib.sol";
import "./libraries/BBP_PositionLib.sol";
import "./libraries/BBP_ValidationLib.sol";
import "./libraries/BBP_DistributionLib.sol";
import "./libraries/BBP_AmplifierLib.sol";
import "./libraries/BBP_SecurityGuards.sol";
import "./libraries/BBP_TeamTierLib.sol";
import "./libraries/BBP_SafeTransferLib.sol";
import "./libraries/BBP_RewardClaimLib.sol";
import "./libraries/BBP_DexLib.sol";
import "./libraries/BBP_AnomalyMonitor.sol";

/**
 * @title BigBullProtocol
 * @notice BigBull V4 main contract - production-grade DeFi team vault
 * @dev Inherits VaultStorage which inherits PriceOracle + ReentrancyGuard
 *
 * SECURITY STACK (17+ layers):
 * 1. nonReentrant - Standard reentrancy guard
 * 2. processingLock - Cross-function lock per user
 * 3. onePerBlock - Same-block protection
 * 4. onlyEOA - EOA-only enforcement (3-layer)
 * 5. whenNotPaused - Emergency pause check
 * 6. minGas - Gas griefing prevention
 * 7. Position locked prices
 * 8. Per-stake 24hr unlock
 * 9. Daily 25% cap (USD)
 * 10. Max withdraw $1000 (USD)
 * 11. TWAP + max(spot, twap)
 * 12. Hardcoded BB/USDT pair (immutable)
 * 13. All wallets immutable
 * 14. Cooldowns (deposit/claim/grace)
 * 15. Volume limits (50/day, 100 lifetime)
 * 16. Liquidity floors
 * 17. Constructor multi-validation
 */

contract BigBullProtocol is VaultStorage {

    using PositionLib for VaultTypes.Position;
    using RewardLib for VaultTypes.Position;
    using AmplifierLib for VaultTypes.UserAccount;
    using SafeTransferLib for address;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        VaultTypes.VaultConfig memory cfg,
        address[] memory guardians_
    ) VaultStorage(cfg, guardians_) {}

    // ═══════════════════════════════════════════════════════════════════════
    // ENROLL FUNCTION (Register new user under referrer)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Enroll as a new user under specified referrer
     * @param referrer_ Address of the referrer (must be enrolled)
     */
    function enroll(address referrer_)
        external
        nonReentrant
        processingLock(msg.sender)
        onePerBlock(msg.sender)
        whenNotPaused
        minGas
    {
        SecurityGuards.validateChain();
        if (isBlocked[msg.sender]) revert VaultTypes.AddressBlocked();
        ValidationLib.validateEOA(msg.sender);

        VaultTypes.UserAccount storage self = users[msg.sender];

        // Self must not already be enrolled
        if (self.isEnrolled) revert VaultTypes.AlreadyEnrolled();

        // Self must not be a blocked system address (defense-in-depth;
        // EOA check already blocks contracts, this blocks zero/dead too)
        _requireNotSystemAddress(msg.sender);

        // Full referrer validation (registered + active + EOA + not system)
        _validateReferrer(msg.sender, referrer_);

        VaultTypes.UserAccount storage refUser = users[referrer_];

        // Hard cap: a single referrer cannot have more than 1000 directs.
        // Prevents unbounded array growth (gas issues on iteration, event spam,
        // and protects future on-chain enumeration features).
        if (_directReferrals[referrer_].length >= VaultConstants.MAX_DIRECTS_PER_REFERRER) {
            revert VaultTypes.MaxDirectsReached();
        }

        // Register
        self.isEnrolled = true;
        self.referrer = referrer_;
        self.enrolledAt = uint64(block.timestamp);
        personalStakeLimit[msg.sender] = VaultConstants.DEFAULT_STAKE_LIMIT;

        // Update referrer's direct count
        _directReferrals[referrer_].push(msg.sender);
        refUser.directsCount += 1;

        totalUsers += 1;

        emit VaultTypes.StakerEnrolled(msg.sender, referrer_, block.timestamp);
    }

    /**
     * @notice Validate a referrer address fully before enrollment.
     * @dev Referrer MUST be: enrolled, an EOA (not a contract), not a system
     *      address (token/pair/router/etc.), not self, and have an ACTIVE stake
     *      of at least $25 (genesis is exempt — it is the protected root).
     */
    function _validateReferrer(address newUser, address referrer) internal view {
        if (referrer == address(0)) revert VaultTypes.ZeroAddress();
        if (newUser == referrer) revert VaultTypes.SelfReferral();

        // Block all known system addresses from being a referrer
        _requireNotSystemAddress(referrer);

        // Referrer must be a pure EOA (no contracts, no EIP-7702 delegated EOAs,
        // no edge-case bytecode patterns). Uses the same extcodehash check as
        // the caller validation; only tx.origin is omitted (referrer is not
        // the caller).
        ValidationLib.validateEOAExternal(referrer);

        VaultTypes.UserAccount storage refUser = users[referrer];

        // Referrer must be registered
        if (!refUser.isEnrolled) revert VaultTypes.ReferrerNotEnrolled();

        // Referrer must have an active stake of at least $25 (genesis exempt)
        if (!refUser.isGenesis) {
            if (refUser.totalDepositUSD < VaultConstants.REFERRER_MIN_ACTIVE_USD) {
                revert VaultTypes.ReferrerNotActive();
            }
        }
    }

    /**
     * @notice Revert if the address is any protected system address.
     * @dev Blocks: zero, dead, BB token, USDT, the BB/USDT pair, the router,
     *      WBNB, and the vault itself. None of these can ever enroll or refer.
     */
    function _requireNotSystemAddress(address a) internal view {
        if (
            a == address(0) ||
            a == DEAD_ADDRESS ||
            a == BIB_TOKEN ||
            a == USDT_TOKEN ||
            a == BIB_USDT_PAIR ||
            a == address(router) ||
            a == WBNB_BSC ||
            a == address(this)
        ) {
            revert VaultTypes.BlockedSystemAddress();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKE FUNCTION (Deposit + create new position)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit USDT and create new staking position
     * @param amount_ USDT amount (must be whole dollar, $10-$5000)
     */
    function stake(uint128 amount_)
        external
        nonReentrant
        processingLock(msg.sender)
        onePerBlock(msg.sender)
        whenNotPaused
        minGas
    {
        _stakeEntry(msg.sender, amount_);
    }

    function _stakeEntry(address staker, uint128 amount_) internal {
        SecurityGuards.validateChain();
        if (isBlocked[msg.sender]) revert VaultTypes.AddressBlocked();
        ValidationLib.validateEOA(staker);
        ValidationLib.validateDepositAmount(amount_);

        VaultTypes.UserAccount storage user = users[staker];
        if (!user.isEnrolled) revert VaultTypes.NotEnrolled();

        // Genesis is the protected root and must never stake (avoids cap/booster
        // edge cases and keeps root status purely as tree origin)
        if (user.isGenesis) revert VaultTypes.GenesisCannotStake();

        _validateStakeTiming(staker, user);
        _processStake(staker, amount_, user);
    }

    function _validateStakeTiming(
        address staker,
        VaultTypes.UserAccount storage user
    ) internal {
        uint64 nowT = uint64(block.timestamp);
        ValidationLib.validateEnrollGrace(user.enrolledAt, nowT);
        ValidationLib.validateReferrerGrace(users[user.referrer].lastDepositAt, nowT);
        ValidationLib.validateDepositCooldown(user.lastDepositAt, nowT);

        (uint16 newCount, uint64 newDay) = ValidationLib.validateDailyDepositLimit(
            lastDepositDay[staker], depositsToday[staker], nowT
        );
        depositsToday[staker] = newCount;
        lastDepositDay[staker] = newDay;

        ValidationLib.validateStakeLimit(
            _positions[staker].length,
            personalStakeLimit[staker]
        );
    }

    /**
     * @notice Internal stake processing - uses struct for stack management
     */
    struct StakeVars {
        uint128 protocolFee;
        uint128 liquidityAmount;
        uint128 swapAmount;
        uint128 lockedPrice;
        uint128 bbReceived;
        uint128 depositBB;
        uint128 capUSD;
        uint8 ampLevel;
    }

    function _processStake(
        address staker,
        uint128 amount_,
        VaultTypes.UserAccount storage user
    ) internal {
        StakeVars memory v;

        // 1. Pre-flight USDT checks (explicit + clear error messages, in addition
        //    to the implicit checks SafeTransferLib performs)
        {
            uint256 userBal = IERC20(USDT_TOKEN).balanceOf(staker);
            if (userBal < amount_) revert VaultTypes.InsufficientUserBalance();
            uint256 allowed = IERC20(USDT_TOKEN).allowance(staker, address(this));
            if (allowed < amount_) revert VaultTypes.InsufficientAllowance();
        }

        // 2. Transfer USDT from user to this protocol (SafeTransferLib reverts on any failure)
        USDT_TOKEN.safeTransferFrom(staker, address(this), amount_);

        // 2. Distribution amounts
        (v.protocolFee, v.liquidityAmount, v.swapAmount) =
            RewardLib.calculateStakeDistribution(amount_);

        // 3. Dev fee
        USDT_TOKEN.safeTransfer(protocolFeeWallet, v.protocolFee);
        totalProtocolFeePaid += v.protocolFee;
        emit VaultTypes.ProtocolFeePaid(staker, v.protocolFee);

        // 4. Locked price
        v.lockedPrice = _getProtectedPrice();

        // 5. Swap for BB (held in vault for payouts) — via DexLib.
        //    Uses v.lockedPrice captured at step 4 (price at swap time = pre-swap).
        v.bbReceived = DexLib.swapUSDTtoBB(
            IDexRouter(address(router)), USDT_TOKEN, BIB_TOKEN,
            v.swapAmount, v.lockedPrice
        );

        // 6. Add liquidity (half-swap + half-USDT, LP to DEAD) — via DexLib.
        //    Re-read the protected price: the step-5 swap just moved spot, so the
        //    liquidity swap must price its slippage off the CURRENT protected price
        //    (max(spot,twap) + deviation guard) — matching the original behaviour.
        uint128 liqPrice = _getProtectedPrice();
        DexLib.addLiquidity(
            IDexRouter(address(router)), USDT_TOKEN, BIB_TOKEN, DEAD_ADDRESS,
            v.liquidityAmount, liqPrice
        );

        // 7-9. Create position
        v.ampLevel = user.getAmplifierLevel();
        v.depositBB = RewardLib.usdToBBAtLockedPrice(amount_, v.lockedPrice);
        v.capUSD = RewardLib.calculateCapUSD(amount_, v.ampLevel);

        _createPositionAndUpdate(staker, amount_, v, user);
    }

    /**
     * @notice Create position and update user state (split to avoid stack depth)
     */
    function _createPositionAndUpdate(
        address staker,
        uint128 amount_,
        StakeVars memory v,
        VaultTypes.UserAccount storage user
    ) internal {
        uint64 nowTime = uint64(block.timestamp);

        VaultTypes.Position memory newPos = PositionLib.createPosition(
            amount_, v.depositBB, v.lockedPrice, v.capUSD, v.ampLevel, nowTime
        );

        _positions[staker].push(newPos);
        uint256 positionId = _positions[staker].length - 1;

        // Update user state
        if (user.firstDepositAt == 0) {
            user.firstDepositAt = nowTime;
            user.amplifierWindowStart = nowTime;
            user.amplifierWindowEnd = nowTime + VaultConstants.AMPLIFIER_WINDOW;

            // ACTIVATION (Image 1 #5): a direct becomes "active" on their first
            // stake (>= $10 minimum, already enforced). Count it for the referrer
            // so Community Level Income / Protocol Flow qualification can pass.
            address ref = user.referrer;
            if (ref != address(0)) {
                users[ref].activeDirectsCount += 1;
            }
        }
        user.lastDepositAt = nowTime;
        user.totalDepositUSD += amount_;
        user.totalDepositBB += v.depositBB;
        // currentCapUSD tracks the TOTAL cap (ROI + working = 3x/4x/5x); the
        // position's own capUSD holds the ROI-only cap (2x/3x/4x).
        user.currentCapUSD += RewardLib.calculateTotalCapUSD(amount_, v.ampLevel);

        // Protocol stats
        totalDepositedUSD += amount_;
        totalStakesCreated += 1;
        totalActivePositions += 1;

        emit VaultTypes.PositionCreated(
            staker, positionId, amount_, v.depositBB,
            v.lockedPrice, v.capUSD, newPos.unlockTime
        );

        // team distribution (full 50-level walk lives in the library)
        TeamTierLib.distributeTeamVolume(
            users, legBusinessUSD,
            salaryAchievers, expansionAchievers, lifestyleAchievers,
            rewardQueue, staker, amount_
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIM FUNCTION (Hybrid: USD limits + BB transfer)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim accrued rewards (BB tokens from unlocked positions)
     */
    function claim()
        external
        nonReentrant
        processingLock(msg.sender)
        onePerBlock(msg.sender)
        whenNotPaused
        minGas
    {
        _claimEntry(msg.sender);
    }

    function _claimEntry(address claimer) internal {
        SecurityGuards.validateChain();
        if (isBlocked[msg.sender]) revert VaultTypes.AddressBlocked();
        ValidationLib.validateEOA(claimer);

        // Global claim switch + per-wallet block (phishing / abuse protection)
        if (!claimsEnabled) revert VaultTypes.ClaimsDisabled();
        if (claimBlocked[claimer]) revert VaultTypes.WalletClaimBlocked();

        VaultTypes.UserAccount storage user = users[claimer];
        if (!user.isEnrolled) revert VaultTypes.NotEnrolled();

        // Only users who have actually staked can claim.
        // Genesis is exempt — it earns purely from the tree, never stakes.
        if (!user.isGenesis && _positions[claimer].length == 0) {
            revert VaultTypes.NoStakeToClaim();
        }

        // Keep genesis cap topped up (never gets stuck as capped)
        if (user.isGenesis) {
            _ensureGenesisCap(claimer);
        }

        uint64 nowT = uint64(block.timestamp);
        ValidationLib.validateFirstClaimLock(user.firstDepositAt, nowT);
        ValidationLib.validateClaimCooldown(user.lastClaimAt, nowT);

        _processClaim(claimer, user);
    }

    struct ClaimVars {
        uint64 newDay;
        uint128 maxAllowedUSD;
        uint128 totalClaimUSD;
        uint128 totalClaimBB;
        uint128 roiUSD;
        uint128 netUSD;
        uint128 netBB;
    }

    function _processClaim(
        address claimer,
        VaultTypes.UserAccount storage user
    ) internal {
        ClaimVars memory v;

        // Daily limit + max withdraw
        (v.newDay, v.maxAllowedUSD) = ValidationLib.validateDailyClaimLimit(
            user.lastClaimDay,
            user.dailyClaimedUSD,
            user.currentCapUSD,
            uint64(block.timestamp)
        );
        if (v.maxAllowedUSD > VaultConstants.MAX_WITHDRAW_USD) {
            v.maxAllowedUSD = VaultConstants.MAX_WITHDRAW_USD;
        }

        // Collect claimable from positions (stake ROI, auto-compounded)
        (v.totalClaimUSD, v.totalClaimBB) = _collectClaimable(
            claimer,
            user.getAmplifierLevel(),
            v.maxAllowedUSD
        );

        // Capture the ROI portion — Community Level Income is paid on this, and it
        // is distributed together with Protocol Flow in a single upline walk later.
        v.roiUSD = v.totalClaimUSD;

        // Add pending passive income (level income + Protocol Flow + salary
        // + one-time rewards) up to whatever daily cap remains after stake ROI.
        uint128 remainingCap = v.maxAllowedUSD - v.totalClaimUSD;
        if (remainingCap > 0) {
            (uint128 pUSD, uint128 pBB) = _collectPendingIncome(user, remainingCap);
            v.totalClaimUSD += pUSD;
            v.totalClaimBB += pBB;
        }

        if (v.totalClaimUSD == 0) revert VaultTypes.NothingToClaim();

        // Update state + transfer
        _finalizeClaim(claimer, user, v);
    }

    /**
     * @notice Collect a user's pending passive income (level matching + Protocol
     *         Flow) up to the remaining daily cap, converting USD→BB at the
     *         protected price. Paid portion is zeroed BEFORE transfer (CEI).
     * @dev Salary / expansion / lifestyle rewards are NOT auto-paid here — those
     *      are tracked on-chain and paid manually per the plan.
     */
    function _collectPendingIncome(
        VaultTypes.UserAccount storage user,
        uint128 remainingCap
    ) internal returns (uint128 usd, uint128 bb) {
        // Accrue salary + collect all pending streams (level, flow, salary,
        // one-time rewards) up to the remaining daily cap. Paid amounts are
        // deducted from storage inside the library BEFORE we transfer (CEI).
        usd = DistributionLib.collectPending(user, uint64(block.timestamp), remainingCap);
        if (usd == 0) return (0, 0);

        // Convert to BB at protected price (max(spot,twap) + deviation guard)
        uint128 price = _getProtectedPrice();
        bb = RewardLib.usdToBBAtLockedPrice(usd, price);
    }

    function _finalizeClaim(
        address claimer,
        VaultTypes.UserAccount storage user,
        ClaimVars memory v
    ) internal {
        // ANOMALY CHECK: detect abnormal claims and auto-pause BEFORE transfer.
        // Genesis is exempt (its large claims are legitimate root payouts).
        // Logic lives in AnomalyMonitor (delegatecall'd) to keep vault < EIP-170.
        if (!user.isGenesis) {
            (uint8 trigger, uint128 amt) = AnomalyMonitor.checkClaim(claimAnomaly, v.totalClaimUSD);
            if (trigger == 1) _autoPause("single claim ceiling", amt);
            else if (trigger == 2) _autoPause("daily claim spike", amt);
        }

        user.lastClaimAt = uint64(block.timestamp);

        // SECURITY: accumulate the daily-claimed total within the SAME day; only
        // reset when the day rolls over. Previously this overwrote the value, which
        // let a user reset the remaining daily limit by claiming partial amounts
        // repeatedly and bypass the daily cap. Compare the OLD lastClaimDay first.
        if (user.lastClaimDay != v.newDay) {
            user.dailyClaimedUSD = v.totalClaimUSD;   // new day → start fresh
        } else {
            user.dailyClaimedUSD += v.totalClaimUSD;  // same day → accumulate
        }
        user.lastClaimDay = v.newDay;

        v.netUSD = _applyUplineDistribution(claimer, v.roiUSD, v.totalClaimUSD);
        v.netBB = uint128((uint256(v.totalClaimBB) * uint256(v.netUSD)) / uint256(v.totalClaimUSD));

        uint256 vaultBalance = IERC20(BIB_TOKEN).balanceOf(address(this));
        ValidationLib.validateVaultBalance(vaultBalance, v.netBB);

        // Genesis claim → equal-split across the 20 treasury nodes (with the
        // remainder going to the last node). All other users receive directly.
        if (claimer == genesisWallet) {
            uint128 sharePerNode = v.netBB / 20;
            if (sharePerNode > 0) {
                for (uint256 i = 0; i < 19; ) {
                    BIB_TOKEN.safeTransfer(treasuryNodes[i], sharePerNode);
                    unchecked { ++i; }
                }
            }
            // Last node absorbs the remainder (handles all division dust)
            uint128 lastShare = v.netBB - sharePerNode * 19;
            if (lastShare > 0) {
                BIB_TOKEN.safeTransfer(treasuryNodes[19], lastShare);
            }
        } else {
            BIB_TOKEN.safeTransfer(claimer, v.netBB);
        }

        user.totalClaimedUSD += v.totalClaimUSD;
        user.totalClaimedBB += v.totalClaimBB;
        totalDistributedBB += v.netBB;

        emit VaultTypes.Claimed(claimer, v.totalClaimUSD, v.netBB, v.totalClaimUSD - v.netUSD);
    }

    /**
     * @notice Detect claim anomalies and auto-pause if thresholds breached.
     * @dev Two triggers:
     *      1. Single claim > singleClaimCeilingUSD
     *      2. Daily total > dailyClaimSpikeMult × 7-day average
     *      On trigger: set paused=true (guardians investigate, then unpause).
     *      Updates rolling daily total + 7-day average on day rotation.
     */
    function _autoPause(string memory reason, uint128 amount) internal {
        paused = true;
        lastAnomalyReason = reason;
        emit VaultTypes.AnomalyAutoPause(reason, amount, block.timestamp);
        // Revert so the triggering claim is not paid out
        revert VaultTypes.EmergencyActive();
    }

    /**
     * @notice Guardians tune anomaly thresholds (before any lock)
     */
    function setAnomalyConfig(uint128 singleCeiling_, uint16 spikeMult_) external onlyGuardian {
        if (singleCeiling_ == 0 || spikeMult_ == 0) revert VaultTypes.InvalidAmount();
        claimAnomaly.singleClaimCeilingUSD = singleCeiling_;
        claimAnomaly.dailyClaimSpikeMult = spikeMult_;
        emit VaultTypes.AnomalyConfigUpdated(singleCeiling_, spikeMult_);
    }

    /**
     * @notice Single-walk upline distribution: Community Level Income (on ROI) +
     *         Protocol Flow (on the 5% deduction), combined to halve gas vs two
     *         separate 50-level walks. Returns the net (post-deduction) USD.
     * @dev    When the 50-level walk encounters skipped/missing/unqualified levels,
     *         the unpaid portion of BOTH income types is accumulated as `dao` and
     *         split equally across the 20 treasury nodes (BBRewardNodesConfig).
     *         Each node receives 1/20 of the accumulated amount; the dust
     *         remainder stays with the vault and is rolled into the next split.
     */
    function _applyUplineDistribution(
        address source,
        uint128 roiUSD,
        uint128 grossUSD
    ) internal returns (uint128 netUSD) {
        (uint128 deduction, uint128 perLevel) =
            DistributionLib.calculateProtocolFlowDeduction(grossUSD);

        uint128 dao = DistributionLib.distributeUplineIncome(users, source, roiUSD, perLevel);
        if (dao > 0) {
            totalDAOGovernorReceived += dao;
            // Convert USD → BB at the current oracle price, then split equally
            // across the 20 treasury nodes (BBRewardNodesConfig). Each node
            // receives sharePerNode = totalBB / 20. The dust (totalBB % 20)
            // remains in the vault.
            uint128 daoBB = RewardLib.usdToBBAtLockedPrice(dao, _getProtectedPrice());
            uint128 sharePerNode = daoBB / 20;
            if (sharePerNode > 0) {
                for (uint256 i = 0; i < 20; ) {
                    SafeTransferLib.safeTransfer(BIB_TOKEN, treasuryNodes[i], sharePerNode);
                    unchecked { ++i; }
                }
            }
        }

        netUSD = grossUSD - deduction;
    }

    function _collectClaimable(
        address claimer,
        uint8 ampLevel,
        uint128 maxAllowedUSD
    ) internal returns (uint128 totalUSD, uint128 totalBB) {
        uint256 len = _positions[claimer].length;
        uint64 currentTime = uint64(block.timestamp);

        for (uint256 i = 0; i < len; i++) {
            (uint128 addUSD, uint128 addBB) = _processOnePosition(
                claimer, i, ampLevel, currentTime, maxAllowedUSD - totalUSD
            );
            totalUSD += addUSD;
            totalBB += addBB;
            if (totalUSD >= maxAllowedUSD) break;
        }
    }

    function _processOnePosition(
        address claimer,
        uint256 idx,
        uint8 ampLevel,
        uint64 currentTime,
        uint128 remainingCap
    ) internal returns (uint128 addUSD, uint128 addBB) {
        VaultTypes.Position storage pos = _positions[claimer][idx];
        if (!pos.active) return (0, 0);
        if (currentTime < pos.unlockTime) return (0, 0);

        PositionLib.updateROI(pos, ampLevel, currentTime);

        addUSD = pos.earnedUSD - pos.claimedUSD;
        addBB = pos.earnedBB - pos.claimedBB;

        if (addUSD == 0) return (0, 0);

        if (addUSD > remainingCap) {
            uint128 ratio = uint128((uint256(remainingCap) * 1e18) / uint256(addUSD));
            addUSD = remainingCap;
            addBB = uint128((uint256(addBB) * uint256(ratio)) / 1e18);
        }

        PositionLib.recordClaim(pos, addUSD, addBB, currentTime);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // team DISTRIBUTION (Matching + Volume Updates)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Distribute matching income to uplines (called on stake)
     * @dev Simplified version - full implementation in production
     */
    /**
     * @notice Update the upline's leg volumes and detect newly achieved tiers.
     * @dev Delegates to the external TeamTierLib (keeps vault bytecode small).
     */
    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL FLOW (5% on claims, distributed 50 levels)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Apply Protocol Flow deduction with DAO Governor for skipped
     * @return netUSD Amount after deduction (95%)
     */
    // ═══════════════════════════════════════════════════════════════════════
    // DEX INTEGRATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap USDT to BB tokens via PancakeSwap
     */
    /**
     * @notice Add liquidity to BB/USDT pool, lock LP to DEAD
     */
    /**
     * @notice Safe token transfer that handles non-standard ERC20s (e.g. BSC USDT
     *         which may not return a bool). Reverts if the transfer fails.
     */
    // ═══════════════════════════════════════════════════════════════════════
    // EMERGENCY FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function emergencyPause() external onlyGuardian {
        if (paused) revert VaultTypes.AlreadyPaused();
        paused = true;
        emit VaultTypes.EmergencyPaused(msg.sender, block.timestamp);
    }

    function emergencyUnpause() external onlyGuardian {
        if (!paused) revert VaultTypes.NotPaused();
        paused = false;
        emit VaultTypes.EmergencyUnpaused(msg.sender, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIM CONTROL (guardian/DAO — phishing & abuse mitigation)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Globally enable/disable claims (independent of full pause).
     */
    function setClaimsEnabled(bool enabled) external onlyGuardian {
        claimsEnabled = enabled;
        emit VaultTypes.ClaimsToggled(enabled);
    }

    /**
     * @notice Block/unblock a specific wallet from claiming.
     * @dev Does NOT seize funds — only halts claims for compromised/abusive
     *      wallets. The genesis wallet can never be blocked.
     */
    function setClaimBlocked(address wallet, bool blocked) external onlyGuardian {
        if (wallet == address(0)) revert VaultTypes.ZeroAddress();
        if (wallet == genesisWallet) revert VaultTypes.GenesisProtected();
        claimBlocked[wallet] = blocked;
        emit VaultTypes.WalletClaimBlockedSet(wallet, blocked);
    }

    /**
     * @notice General-purpose blocklist — blocks msg.sender from enroll/stake/claim/claimReward.
     *         Settable by any guardian at any time (no lock, no renounce dependency).
     *         Defense in depth on top of the token-level flashloan blocklist.
     *         Genesis wallet cannot be blocked.
     */
    function setBlocked(address account, bool blocked) external onlyGuardian {
        if (account == address(0)) revert VaultTypes.ZeroAddress();
        if (account == genesisWallet) revert VaultTypes.GenesisProtected();
        isBlocked[account] = blocked;
        emit VaultTypes.AddressBlockedSet(account, blocked);
    }

    function setBlockedBatch(address[] calldata accounts, bool blocked) external onlyGuardian {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ) {
            address a = accounts[i];
            if (a == address(0)) revert VaultTypes.ZeroAddress();
            if (a == genesisWallet) revert VaultTypes.GenesisProtected();
            isBlocked[a] = blocked;
            emit VaultTypes.AddressBlockedSet(a, blocked);
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PERFORMANCE REWARD CLAIM (separate, secure, installment-based)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Release the next installment of your earned Performance Reward.
     * @dev Uses msg.sender only — no tier or amount parameter, so a caller can
     *      only ever release their OWN queued rewards. Each reward is released
     *      in 4 parts, 6 hours apart; the released amount lands in your claimable
     *      balance and is paid out as BB via the normal claim() (price-protected,
     *      daily-capped). One grant processes at a time; the next starts only
     *      after the current one finishes — pacing rewards to ~one per day.
     */
    function claimReward()
        external
        nonReentrant
        processingLock(msg.sender)
        onePerBlock(msg.sender)
        whenNotPaused
        minGas
    {
        address claimer = msg.sender;
        if (isBlocked[claimer]) revert VaultTypes.AddressBlocked();
        ValidationLib.validateEOA(claimer);
        if (!users[claimer].isEnrolled) revert VaultTypes.NotEnrolled();
        if (!claimsEnabled) revert VaultTypes.ClaimsDisabled();
        if (claimBlocked[claimer]) revert VaultTypes.WalletClaimBlocked();

        // Separate cooldown from regular claim() — Performance Rewards pace independently.
        uint64 nowT = uint64(block.timestamp);
        uint64 lastAt = lastRewardClaimAt[claimer];
        if (lastAt != 0 && nowT < lastAt + VaultConstants.REWARD_CLAIM_COOLDOWN) {
            revert VaultTypes.RewardTimerActive();
        }

        // Single full-release model: moves the FULL ripened reward into pendingExpansion.
        // The user then runs claim() to receive BB tokens, draining pendingExpansion under
        // the normal 25%-of-cap daily limit (no special bypass — capping is shared).
        (uint256 newHead, ) = RewardClaimLib.claimReward(
            rewardQueue[claimer],
            users[claimer],
            rewardQueueHead[claimer],
            nowT
        );
        rewardQueueHead[claimer] = newHead;
        lastRewardClaimAt[claimer] = nowT;
    }

    /// @notice Number of reward grants ever queued for a user.
    function rewardQueueLength(address user) external view returns (uint256) {
        return rewardQueue[user].length;
    }

    function finalizeLaunch() external onlyOwner {
        if (launchFinalized) revert VaultTypes.LaunchAlreadyFinalized();
        launchFinalized = true;
        owner = address(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ACHIEVER REGISTRY VIEWS (counts; full reads via VaultReader)
    // ═══════════════════════════════════════════════════════════════════════

    function salaryAchieverCount() external view returns (uint256) {
        return salaryAchievers.length;
    }

    function expansionAchieverCount() external view returns (uint256) {
        return expansionAchievers.length;
    }

    function lifestyleAchieverCount() external view returns (uint256) {
        return lifestyleAchievers.length;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VAULT REFILL (Cold treasury → hot vault, with timelock)
    // ═══════════════════════════════════════════════════════════════════════

    function proposeRefill(uint128 amount) external onlyGuardian {
        if (amount == 0) revert VaultTypes.InvalidRefillAmount();
        if (pendingRefill.unlockTime != 0 && !pendingRefill.executed) {
            revert VaultTypes.RefillTimelockActive();
        }

        pendingRefill = PendingRefill({
            amount: amount,
            unlockTime: uint64(block.timestamp + VaultConstants.REFILL_TIMELOCK),
            executed: false
        });
    }

    function executeRefill() external onlyGuardian {
        PendingRefill memory pr = pendingRefill;
        if (pr.unlockTime == 0) revert VaultTypes.InvalidRefillAmount();
        if (pr.executed) revert VaultTypes.InvalidRefillAmount();
        if (block.timestamp < pr.unlockTime) revert VaultTypes.RefillTimelockActive();

        // Reset daily counter if new day
        uint64 today = uint64(block.timestamp / VaultConstants.DAY);
        if (today != lastRefillDay) {
            refilledTodayAmount = 0;
            lastRefillDay = today;
        }

        if (refilledTodayAmount + pr.amount > VaultConstants.MAX_REFILL_PER_DAY) {
            revert VaultTypes.InvalidRefillAmount();
        }
        refilledTodayAmount += pr.amount;
        totalRefilled += pr.amount;

        pendingRefill.executed = true;

        // Pull from cold treasury (must have pre-approved)
        BIB_TOKEN.safeTransferFrom(coldTreasury, address(this), pr.amount);

        emit VaultTypes.VaultRefilled(pr.amount, block.timestamp);
    }
}
