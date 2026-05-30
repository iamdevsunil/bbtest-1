// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./BBP_Types.sol";
import "./BBP_Constants.sol";
import "./BBP_PriceOracle.sol";
import "./BBP_RewardNodes.sol";
import "./interfaces/IERC20.sol";
import "./access/BBP_ReentrancyGuard.sol";

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);
}

/**
 * @title VaultStorage
 * @notice All state variables, mappings, and immutable addresses for BigBull V4
 * @dev Separated from logic for clarity and gas optimization
 *
 * IMMUTABLE WALLETS (set in constructor, cannot change):
 * - protocolFeeWallet: 5% USDT on deposits
 * - treasuryWallet: Genesis BIB payouts
 * - genesisWallet: Root team user
 * - daoGovernorWallet: Skipped Protocol Flow
 * - coldTreasury: Multisig for vault refills
 */

abstract contract VaultStorage is ReentrancyGuard, PriceOracle {

    // ═══════════════════════════════════════════════════════════════════════
    // IMMUTABLE WALLET ADDRESSES (5 wallets)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Genesis wallet - root team user with unlimited cap
    address public immutable genesisWallet;

    /// @notice Protocol-fee wallet - receives 5% USDT on every deposit
    address public immutable protocolFeeWallet;

    /// @notice Treasury wallet - receives BIB payouts for genesis
    address public immutable treasuryWallet;

    /// @notice Treasury node set (20 wallets). The BB-11 skipped-income
    ///         fallback is split equally across these 20 wallets (1/20 each).
    ///         INTERNAL visibility — accessible to the inheriting vault but
    ///         exposes NO public getter. Addresses are configured statically
    ///         in BBRewardNodesConfig.sol before compile.
    address[20] internal treasuryNodes;

    /// @notice Cold Treasury - holds majority BB tokens for refills (multisig)
    address public immutable coldTreasury;

    // ═══════════════════════════════════════════════════════════════════════
    // IMMUTABLE PROTOCOL ADDRESSES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice PancakeSwap V2 Router
    IPancakeRouter public immutable router;

    /// @notice WBNB BSC mainnet address — hardcoded constant.
    /// @dev    Used only as a defensive blocklist entry in
    ///         `_requireNotSystemAddress` to prevent WBNB from being passed
    ///         as a referrer or appearing as a user account. The protocol
    ///         performs no swaps through WBNB (BB/USDT is the direct pair),
    ///         so this address is never moved by the vault. Hardcoded because
    ///         BSC WBNB is a fixed well-known address and the contract is
    ///         BSC-only by design.
    address internal constant WBNB_BSC = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice DEAD address for LP burning
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ═══════════════════════════════════════════════════════════════════════
    // CORE MAPPINGS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice User team aggregate data
    mapping(address => VaultTypes.UserAccount) public users;

    /// @notice User's positions (multiple stakes)
    mapping(address => VaultTypes.Position[]) internal _positions;

    /// @notice Direct referrals of each user
    mapping(address => address[]) internal _directReferrals;

    /// @notice Direct referrer's index in their list (for O(1) lookup)
    mapping(address => uint256) internal _referrerIndex;

    /// @notice Daily deposit count per user (resets on new day)
    mapping(address => uint64) public lastDepositDay;
    mapping(address => uint16) public depositsToday;

    /// @notice User's personal stake limit (starts at 50, +25 per week)
    mapping(address => uint16) public personalStakeLimit;
    mapping(address => uint64) public lastStakeLimitIncrease;

    // ═══════════════════════════════════════════════════════════════════════
    // PROTOCOL STATS (Aggregate)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total USDT ever deposited
    uint128 public totalDepositedUSD;

    /// @notice Total BB ever distributed
    uint128 public totalDistributedBB;

    /// @notice Total USDT paid to protocol-fee wallet
    uint128 public totalProtocolFeePaid;

    /// @notice Total amount sent to DAO Governor
    uint128 public totalDAOGovernorReceived;

    /// @notice Total amount in cold treasury (tracked)
    uint128 public totalRefilled;

    /// @notice Total enrolled users
    uint64 public totalUsers;

    /// @notice Total active positions
    uint64 public totalActivePositions;

    /// @notice Total stakes lifetime
    uint64 public totalStakesCreated;

    // ═══════════════════════════════════════════════════════════════════════
    // OWNER & EMERGENCY CONTROLS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Contract owner (renounceable)
    address public owner;

    /// @notice True after launch is finalized (renounces ownership permanently)
    bool public launchFinalized;

    /// @notice Emergency pause state
    bool public paused;

    /// @notice Anomaly detection auto-pause
    bool public anomalyPaused;

    /// @notice Emergency guardians (multisig members)
    mapping(address => bool) public guardians;

    /// @notice Generic addresses blocked from interacting with the protocol.
    /// @dev    Settable by any guardian at any time (no lock). Defense in depth
    ///         on top of token-level flashloan blocklist.
    mapping(address => bool) public isBlocked;
    uint8 public guardianCount;

    /// @notice Pending refill data
    struct PendingRefill {
        uint128 amount;
        uint64 unlockTime;
        bool executed;
    }
    PendingRefill public pendingRefill;

    /// @notice Refill tracking
    uint128 public refilledTodayAmount;
    uint64 public lastRefillDay;

    // ═══════════════════════════════════════════════════════════════════════
    // ANOMALY AUTO-PAUSE STATE (lightweight, gas-safe)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Packed claim-anomaly state (struct in VaultTypes).
    ///         Replaces the previous 7 individual variables to (a) enable passing
    ///         a storage ref to the external AnomalyMonitor library and (b)
    ///         reduce vault bytecode below EIP-170. Public getter is auto-
    ///         generated for backwards-compatible external reads.
    VaultTypes.ClaimAnomalyData public claimAnomaly;

    /// @notice Reason string for last auto-pause (for transparency)
    string public lastAnomalyReason;

    // ═══════════════════════════════════════════════════════════════════════
    // LEG / TEAM BUSINESS TRACKING (team plan core)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Per-user, per-direct-leg business volume (USD)
    ///         legBusinessUSD[user][directLegRoot] = total volume under that leg
    mapping(address => mapping(address => uint128)) public legBusinessUSD;

    // ═══════════════════════════════════════════════════════════════════════
    // ACHIEVER REGISTRIES (on-chain tracking only; rewards paid manually)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Achiever logs - newest entries appended at the end
    VaultTypes.Achiever[] public salaryAchievers;     // Performance Salary Bonus (2-leg)
    VaultTypes.Achiever[] public expansionAchievers;  // Performance Rewards (3-leg)
    VaultTypes.Achiever[] public lifestyleAchievers;  // Dream Lifestyle & Travel Rewards

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIM CONTROL (global switch + per-wallet block for phishing/abuse)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Global claim switch (guardians can pause all claims independently
    ///         of the full emergency pause). Stakes/enroll remain unaffected.
    bool public claimsEnabled = true;

    /// @notice Wallets blocked from claiming (compromised / phishing / abusive).
    ///         Blocking does NOT seize funds; it only halts that wallet's claims.
    mapping(address => bool) public claimBlocked;

    // ═══════════════════════════════════════════════════════════════════════
    // PERFORMANCE REWARD QUEUE (one-time rewards released in 4 installments)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice FIFO queue of achieved performance rewards awaiting installment release
    mapping(address => VaultTypes.RewardGrant[]) public rewardQueue;

    /// @notice Index of the currently-processing grant in each user's queue
    mapping(address => uint256) public rewardQueueHead;

    /// @notice Per-user timestamp of last claimReward() call — enforces the
    ///         REWARD_CLAIM_COOLDOWN (24h) between consecutive claimReward calls.
    ///         Separate from CLAIM_COOLDOWN, so regular claims and reward claims have
    ///         independent timers.
    mapping(address => uint64) public lastRewardClaimAt;

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy BigBull V4 vault with all immutable configuration
     * @dev All addresses validated and stored immutably - cannot change after deployment
     */
    constructor(
        VaultTypes.VaultConfig memory cfg,
        address[] memory guardians_
    )
        PriceOracle(cfg.pairAddress, cfg.bibToken, cfg.usdtToken)
    {
        // === ADDRESS VALIDATION ===

        if (cfg.router == address(0)) revert VaultTypes.ZeroAddress();
        if (cfg.genesis == address(0)) revert VaultTypes.ZeroAddress();
        if (cfg.protocolFee == address(0)) revert VaultTypes.ZeroAddress();
        if (cfg.treasury == address(0)) revert VaultTypes.ZeroAddress();
        if (cfg.coldTreasury == address(0)) revert VaultTypes.ZeroAddress();

        // === DUPLICATE WALLET CHECK ===

        if (cfg.genesis == cfg.protocolFee) revert VaultTypes.ZeroAddress();
        if (cfg.genesis == cfg.treasury) revert VaultTypes.ZeroAddress();
        if (cfg.genesis == cfg.coldTreasury) revert VaultTypes.ZeroAddress();
        if (cfg.protocolFee == cfg.treasury) revert VaultTypes.ZeroAddress();

        // === GENESIS — any non-zero wallet is allowed (EOA, multi-sig, AA, etc.) ===
        // Strict bytecode/extcodehash checks were removed because they broke
        // legitimate users on modern wallets (MetaMask Smart Account, Coinbase
        // Smart Wallet, Safe, Trust Wallet AA). The actual flash-loan attack
        // vector is contract-to-contract calls — blocked by tx.origin check on
        // enroll/stake/claim mutations in BigBullProtocol.

        // === STORE IMMUTABLES ===

        router = IPancakeRouter(cfg.router);

        genesisWallet = cfg.genesis;
        if (cfg.protocolFee == cfg.treasury) revert VaultTypes.ZeroAddress();
        if (cfg.genesis == cfg.coldTreasury) revert VaultTypes.ZeroAddress();
        if (cfg.protocolFee == cfg.coldTreasury) revert VaultTypes.ZeroAddress();
        if (cfg.treasury == cfg.coldTreasury) revert VaultTypes.ZeroAddress();

        protocolFeeWallet = cfg.protocolFee;
        treasuryWallet = cfg.treasury;
        coldTreasury = cfg.coldTreasury;

        // Initialize the 20-wallet treasury-node set from the static config file.
        // Addresses are baked in at compile time (BBRewardNodesConfig.sol) and
        // are NOT exposed via any public getter on the deployed vault.
        address[20] memory nodes = BBRewardNodesConfig.getNodes();
        for (uint256 i = 0; i < 20; ) {
            if (nodes[i] == address(0)) revert VaultTypes.ZeroAddress();
            treasuryNodes[i] = nodes[i];
            unchecked { ++i; }
        }

        owner = msg.sender;

        // === INITIALIZE GENESIS USER ===

        VaultTypes.UserAccount storage g = users[cfg.genesis];
        g.isEnrolled = true;
        g.enrolledAt = uint64(block.timestamp);
        g.firstDepositAt = uint64(block.timestamp);
        g.lastDepositAt = uint64(block.timestamp);
        g.amplifierWindowStart = uint64(block.timestamp);
        g.amplifierWindowEnd = uint64(block.timestamp) + VaultConstants.AMPLIFIER_WINDOW;

        // Genesis is the protected root - flag prevents re-achieve & staking
        g.isGenesis = true;

        // Genesis has all amplifiers from start (set once, never re-evaluated
        // because _checkAmplifier skips isGenesis users → no re-achieve bug)
        g.silverAchieved = true;
        g.goldAchieved = true;
        g.diamondAchieved = true;
        g.silverAchievedAt = uint64(block.timestamp);
        g.goldAchievedAt = uint64(block.timestamp);
        g.diamondAchievedAt = uint64(block.timestamp);

        // Logical seed deposit (not real USDT - genesis never stakes)
        g.totalDepositUSD = VaultConstants.ROOT_SEED_DEPOSIT;
        // Genesis cap starts at the unlimited sentinel; _ensureGenesisCap()
        // tops it back up if it ever gets drawn down, keeping it effectively
        // unlimited without overflow risk.
        g.currentCapUSD = VaultConstants.ROOT_MAX_CAP_USD;

        totalUsers = 1;
        personalStakeLimit[cfg.genesis] = VaultConstants.DEFAULT_STAKE_LIMIT;

        // === ANOMALY DEFAULTS ===
        // Single claim above $5,000 OR daily total above 3x average → auto-pause.
        // These are conservative starting values; guardians can tune pre-lock.
        claimAnomaly.singleClaimCeilingUSD = 5000e18;
        claimAnomaly.dailyClaimSpikeMult = 3;

        // === INITIALIZE GUARDIANS ===
        uint256 gLen = guardians_.length;
        if (gLen < 3 || gLen > 5) revert VaultTypes.ZeroAddress(); // Need 3-5 guardians
        for (uint256 i = 0; i < gLen; i++) {
            if (guardians_[i] == address(0)) revert VaultTypes.ZeroAddress();
            if (guardians[guardians_[i]]) revert VaultTypes.ZeroAddress(); // No duplicates
            guardians[guardians_[i]] = true;
        }
        guardianCount = uint8(gLen);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BASIC GETTERS
    // ═══════════════════════════════════════════════════════════════════════

    function getPositionCount(address user) external view returns (uint256) {
        return _positions[user].length;
    }

    function getPosition(address user, uint256 id) external view returns (VaultTypes.Position memory) {
        if (id >= _positions[user].length) revert VaultTypes.InvalidPositionId();
        return _positions[user][id];
    }

    function getDirectsCount(address user) external view returns (uint256) {
        return _directReferrals[user].length;
    }

    function getDirect(address user, uint256 index) external view returns (address) {
        if (index >= _directReferrals[user].length) revert VaultTypes.InvalidPositionId();
        return _directReferrals[user][index];
    }

    function isGuardian(address account) external view returns (bool) {
        return guardians[account];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert VaultTypes.UnauthorizedCaller();
        _;
    }

    modifier onlyGuardian() {
        if (!guardians[msg.sender]) revert VaultTypes.UnauthorizedCaller();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert VaultTypes.EmergencyActive();
        if (anomalyPaused) revert VaultTypes.EmergencyActive();
        _;
    }

    modifier onlyEOA() {
        // Block contract-to-contract calls only. Modern wallets (Smart Account,
        // multi-sig, AA) pass because tx.origin remains the user's signing EOA.
        if (msg.sender != tx.origin) revert VaultTypes.NotEOA();
        _;
    }

    modifier minGas() {
        if (gasleft() < VaultConstants.MIN_GAS_REQUIRED) {
            revert VaultTypes.InsufficientGas();
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GENESIS PROTECTION HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Keep genesis cap effectively unlimited without overflow.
     * @dev Genesis earns from the tree but should never become "capped".
     *      If its remaining cap (capUSD - earnedUSD) ever falls below a
     *      threshold, top the cap back up to the sentinel. This avoids both
     *      (a) genesis getting stuck as capped, and (b) an unbounded number
     *      that could overflow uint128. Called on genesis claims.
     */
    function _ensureGenesisCap(address account) internal {
        VaultTypes.UserAccount storage u = users[account];
        if (!u.isGenesis) return;

        // If earned has consumed more than half the sentinel, reset the
        // baseline so remaining cap stays large but bounded.
        uint128 sentinel = VaultConstants.ROOT_MAX_CAP_USD;
        if (u.totalEarnedUSD > sentinel / 2) {
            // Re-anchor: capUSD = earnedUSD + full sentinel headroom
            // (capped to max uint128 to prevent overflow)
            uint256 newCap = uint256(u.totalEarnedUSD) + uint256(sentinel);
            if (newCap > type(uint128).max) {
                newCap = type(uint128).max;
            }
            u.currentCapUSD = uint128(newCap);
        }

        // Genesis can never be flagged capped
        u.isCapped = false;
    }
}
