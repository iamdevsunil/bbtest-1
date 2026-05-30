// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title BigBullToken
 * @notice Fixed-supply BEP-20 token for the BigBull protocol.
 * @dev Security model (see docs/TOKEN_SECURITY.md for full rationale):
 *      - Fixed supply minted once in the constructor; no mint function exists.
 *      - One officialPair (BB/USDT, PancakeSwap V2). Buying from the pair is
 *        permanently blocked except for the single stakingContract address
 *        (the BigBull vault), which is set ONCE by the deployer and cannot
 *        ever change.
 *      - Transfers to/from any non-whitelisted contract revert (no secondary
 *        pools, no aggregator routes, no flash-swap exploit contracts).
 *      - Per-receive amount lock: every receipt of >= RECEIVE_LOCK_MIN_AMOUNT
 *        is independently locked for RECEIVE_LOCK seconds. Each amount unlocks
 *        on its own schedule; new receipts do not extend old locks. Defeats
 *        same-tx claim-and-sell flashloan attacks AND dust-griefing.
 *      - address(0) checked on every input; ERC-20 math uses Solidity 0.8.20
 *        built-in overflow checks (no SafeMath wrapper).
 *      - No selfdestruct, no delegatecall, no payable, no assembly-based
 *        balance edits, no owner ability to mint/burn/edit user balances.
 *      - Sell limits removed (was audit issue — replaced by per-receive lock).
 *      - Two-step ownership transfer + irreversible renounceOwnership gated
 *        on all configuration locks.
 */

interface IPairValidator {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

contract BigBullToken {

    // ═══════════════════════════════════════════════════════════════════════
    // IMMUTABLE TOKEN METADATA
    // ═══════════════════════════════════════════════════════════════════════

    string  private _name;
    string  private _symbol;
    uint8   public  constant decimals = 18;
    uint256 public  immutable totalSupply;
    address public  immutable USDT;

    // ═══════════════════════════════════════════════════════════════════════
    // BALANCES & ALLOWANCES
    // ═══════════════════════════════════════════════════════════════════════

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ═══════════════════════════════════════════════════════════════════════
    // OWNERSHIP (permanently locked to deployer — NO transfer, NO renounce)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // `owner` is set exactly once in the constructor and is `immutable` at the
    // EVM level. Both `transferOwnership` and `renounceOwnership` are present
    // for ABI compatibility but always revert with OwnershipLocked. There is
    // no bypass and no upgrade path.
    //
    // Trade-off: if the owner key is ever lost, no future flashloan-provider
    // blocklist additions are possible. The deployer key must be kept offline
    // and recovered safely.

    address public immutable owner;

    // ═══════════════════════════════════════════════════════════════════════
    // PAIR & TRADING CONTROL
    // ═══════════════════════════════════════════════════════════════════════

    address public officialPair;
    bool    public pairLocked;
    bool    public tradingEnabled;
    uint256 public tradingEnabledBlock;
    uint256 public constant ANTISNIPE_BLOCKS = 3;

    /// @notice PancakeSwap V2 Factory on BSC mainnet. The official pair
    ///         MUST equal `factory.getPair(this, USDT)` — owner cannot set
    ///         any other address as the pair, even by mistake.
    address public constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    /// @notice The ONLY address that can receive BB from the official pair.
    ///         Set once by the deployer (typically the BigBull vault). After
    ///         set, cannot change — gates the entire buy path.
    address public stakingContract;

    /// @notice General-purpose whitelist for the protocol's system contracts
    ///         (vault, router, configured operational wallets). Whitelisted
    ///         addresses bypass the receive-lock and contract-blocking rules.
    ///         The buy gate is independent (see stakingContract).
    mapping(address => bool) public isWhitelisted;
    bool public whitelistLocked;

    // ═══════════════════════════════════════════════════════════════════════
    // PER-RECEIVE LOCK QUEUE (anti-flashloan, anti-dust-grief)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Duration each received amount is locked for.
    uint256 public constant RECEIVE_LOCK = 5 minutes;

    /// @notice Minimum amount that triggers a receive-lock entry.
    ///         Set to 1 wei — every non-zero receive is independently locked.
    ///         A separate 5-minute timer applies per amount.
    uint256 public constant RECEIVE_LOCK_MIN_AMOUNT = 1;

    /// @notice Maximum number of pending lock entries per address. Bounds
    ///         worst-case gas. When full, new receives still succeed but
    ///         do NOT get individually locked (the receive amount becomes
    ///         immediately spendable). Attacker cannot use this to drain
    ///         anyone — only the recipient's own protection is reduced.
    uint256 public constant MAX_PENDING_LOCKS = 50;

    struct ReceiveLockEntry {
        uint128 amount;     // BB amount locked (fits 1.7e20 BB = 170B BB ≫ supply)
        uint64  unlockAt;   // timestamp when this entry unlocks
    }

    mapping(address => ReceiveLockEntry[]) private _pendingLocks;

    // ═══════════════════════════════════════════════════════════════════════
    // FLASHLOAN-PROVIDER BLOCKLIST
    // ═══════════════════════════════════════════════════════════════════════

    mapping(address => bool) public isBlockedFlashloanProvider;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipLockedForever(address indexed permanentOwner);
    event PairSet(address indexed pair);
    event PairLockedForever();
    event TradingEnabled(uint256 blockNumber);
    event StakingContractSet(address indexed stakingContract);
    event WhitelistUpdated(address indexed account, bool status);
    event WhitelistLockedForever();
    event FlashloanProviderUpdated(address indexed provider, bool blocked);
    event ReceiveLockAdded(address indexed account, uint128 amount, uint64 unlockAt);

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error InsufficientUnlocked();        // tried to move locked tokens
    error NotOwner();
    error OwnershipLocked();
    error NotAContract();
    error TradingNotEnabled();
    error TradingAlreadyEnabled();
    error BuyingBlocked();
    error BlockedContract();
    error PairAlreadySet();
    error PairIsLocked();
    error WhitelistIsLocked();
    error InvalidPair();
    error SamePair();
    error SnipeBlocked();
    error StakingContractAlreadySet();
    error FlashloanProviderBlocked();

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address usdt_
    ) {
        if (usdt_ == address(0)) revert ZeroAddress();
        if (supply_ == 0) revert ZeroAmount();

        _name = name_;
        _symbol = symbol_;
        USDT = usdt_;

        uint256 supplyWithDecimals = supply_ * (10 ** uint256(decimals));
        totalSupply = supplyWithDecimals;
        owner = msg.sender;
        emit OwnershipLockedForever(msg.sender);
        _balances[msg.sender] = supplyWithDecimals;
        isWhitelisted[msg.sender] = true;

        emit Transfer(address(0), msg.sender, supplyWithDecimals);
        emit WhitelistUpdated(msg.sender, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-20 VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }
    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    /**
     * @notice Sum of all RECEIVED amounts still inside their 5-minute lock
     *         window. The unlocked portion is `balanceOf - lockedBalance`.
     */
    function lockedBalance(address account) public view returns (uint256 locked) {
        if (isWhitelisted[account]) return 0;
        ReceiveLockEntry[] storage locks = _pendingLocks[account];
        uint256 nowT = block.timestamp;
        uint256 len = locks.length;
        for (uint256 i = 0; i < len; ) {
            if (locks[i].unlockAt > nowT) locked += locks[i].amount;
            unchecked { ++i; }
        }
    }

    function unlockedBalance(address account) external view returns (uint256) {
        uint256 bal = _balances[account];
        uint256 locked = lockedBalance(account);
        return bal > locked ? bal - locked : 0;
    }

    function pendingLockCount(address account) external view returns (uint256) {
        return _pendingLocks[account].length;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-20 WRITE
    // ═══════════════════════════════════════════════════════════════════════

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        uint256 currentAllowance = _allowances[msg.sender][spender];
        _approve(msg.sender, spender, currentAllowance + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        uint256 currentAllowance = _allowances[msg.sender][spender];
        if (currentAllowance < subtractedValue) revert InsufficientAllowance();
        unchecked {
            _approve(msg.sender, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CORE TRANSFER LOGIC
    // ═══════════════════════════════════════════════════════════════════════

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance();

        bool fromWL = isWhitelisted[from];
        bool toWL   = isWhitelisted[to];

        // ── 1. WHITELIST FAST-PATH ──────────────────────────────────────────
        // Whitelisted parties (vault, deployer pre-lock, configured wallets)
        // bypass all rules EXCEPT the structural buy block, which is checked
        // first below.
        if (from == officialPair) {
            // ── 2. BUY GATE — only stakingContract may receive ──────────────
            // No whitelist exception. The single stakingContract is the
            // ONLY address that can ever receive BB from the pair (set once,
            // locked from the moment of set). Defeats any path to public buy.
            if (to != stakingContract) revert BuyingBlocked();
            _rawTransfer(from, to, amount);
            return;
        }

        if (fromWL || toWL) {
            // Sending FROM a whitelisted address (vault → user during claim)
            // OR sending TO a whitelisted address (deposits to vault).
            _rawTransfer(from, to, amount);
            return;
        }

        // ── 3. PER-RECEIVE LOCK ENFORCEMENT ─────────────────────────────────
        // The sender must leave at least `lockedBalance(from)` BB in their
        // account after the transfer. This means every locked entry stays
        // locked until its own unlockAt, regardless of new activity.
        _purgeExpiredLocks(from);
        uint256 stillLocked = _sumLocked(from);
        if (fromBalance - amount < stillLocked) revert InsufficientUnlocked();

        // ── 4. FLASHLOAN-PROVIDER BLOCKLIST ─────────────────────────────────
        if (from != officialPair && to != officialPair) {
            if (isBlockedFlashloanProvider[from] || isBlockedFlashloanProvider[to]) {
                revert FlashloanProviderBlocked();
            }
        }

        // ── 5. TRADING GATE ─────────────────────────────────────────────────
        if (!tradingEnabled) revert TradingNotEnabled();

        bool toPair = (to == officialPair);

        // ── 6. SINGLE-PAIR ENFORCEMENT ──────────────────────────────────────
        if (!toPair && _isContract(to))   revert BlockedContract();
        if (_isContract(from))            revert BlockedContract();

        // ── 7. ANTI-SNIPE (sells in first ANTISNIPE_BLOCKS) ─────────────────
        if (toPair && block.number <= tradingEnabledBlock + ANTISNIPE_BLOCKS) {
            revert SnipeBlocked();
        }

        _rawTransfer(from, to, amount);
    }

    function _rawTransfer(address from, address to, uint256 amount) private {
        uint256 fromBalance = _balances[from];
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        // Per-receive lock: add an entry for EVERY non-zero receipt to a
        // non-whitelisted recipient. Each amount gets its own independent
        // 5-minute timer; no dust exemption. After 5 minutes the recipient
        // can transfer / approve / swap that amount.
        if (!isWhitelisted[to] && amount > 0) {
            _addLockEntry(to, amount);
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (owner_ == address(0)) revert ZeroAddress();
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) private {
        uint256 currentAllowance = _allowances[owner_][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert InsufficientAllowance();
            unchecked {
                _approve(owner_, spender, currentAllowance - amount);
            }
        }
    }

    function _isContract(address account) private view returns (bool) {
        return account.code.length > 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RECEIVE-LOCK INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _addLockEntry(address account, uint256 amount) private {
        ReceiveLockEntry[] storage locks = _pendingLocks[account];
        // Opportunistically purge expired entries before pushing — keeps queue
        // bounded under normal use.
        _purgeExpiredLocks(account);
        // If still at max after purge, silently skip the lock (recipient loses
        // protection on this particular receipt, but cannot be DoS'd).
        if (locks.length >= MAX_PENDING_LOCKS) return;
        uint64 unlockAt = uint64(block.timestamp + RECEIVE_LOCK);
        locks.push(ReceiveLockEntry({ amount: uint128(amount), unlockAt: unlockAt }));
        emit ReceiveLockAdded(account, uint128(amount), unlockAt);
    }

    function _purgeExpiredLocks(address account) private {
        ReceiveLockEntry[] storage locks = _pendingLocks[account];
        uint256 len = locks.length;
        if (len == 0) return;
        uint256 nowT = block.timestamp;
        uint256 writeIdx = 0;
        for (uint256 i = 0; i < len; ) {
            if (locks[i].unlockAt > nowT) {
                if (writeIdx != i) locks[writeIdx] = locks[i];
                unchecked { ++writeIdx; }
            }
            unchecked { ++i; }
        }
        while (locks.length > writeIdx) locks.pop();
    }

    function _sumLocked(address account) private view returns (uint256 locked) {
        ReceiveLockEntry[] storage locks = _pendingLocks[account];
        uint256 len = locks.length;
        for (uint256 i = 0; i < len; ) {
            locked += locks[i].amount;
            unchecked { ++i; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PAIR MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    function setOfficialPair(address pair_) external onlyOwner {
        _setOfficialPair(pair_);
    }

    function _setOfficialPair(address pair_) private {
        if (pairLocked) revert PairIsLocked();
        if (pair_ == address(0)) revert ZeroAddress();
        if (pair_ == officialPair) revert SamePair();
        if (!_validatePair(pair_)) revert InvalidPair();

        // STRICT factory verification — the candidate pair MUST be the exact
        // address returned by `factory.getPair(this, USDT)`. This prevents
        // the owner from ever locking-in a non-canonical pair (e.g. a
        // hand-crafted contract that mimics the IPancakePair ABI). The
        // factory result is deterministic — if no pair exists yet, this
        // returns address(0) and reverts here, forcing the deployer to
        // create the pair via `factory.createPair(this, USDT)` first.
        address expected = IPancakeFactory(PANCAKE_FACTORY).getPair(address(this), USDT);
        if (pair_ != expected || expected == address(0)) revert InvalidPair();

        officialPair = pair_;
        emit PairSet(pair_);
    }

    /**
     * @notice Atomic set + lock — strongly recommended over the two-step path.
     */
    function setAndLockPair(address pair_) external onlyOwner {
        _setOfficialPair(pair_);
        pairLocked = true;
        emit PairLockedForever();
    }

    function lockPair() external onlyOwner {
        if (officialPair == address(0)) revert InvalidPair();
        if (pairLocked) revert PairIsLocked();
        pairLocked = true;
        emit PairLockedForever();
    }

    function _validatePair(address pair_) private view returns (bool) {
        try IPairValidator(pair_).token0() returns (address t0) {
            try IPairValidator(pair_).token1() returns (address t1) {
                bool hasThis = (t0 == address(this)) || (t1 == address(this));
                bool hasUSDT = (t0 == USDT) || (t1 == USDT);
                return hasThis && hasUSDT;
            } catch { return false; }
        } catch { return false; }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STAKING CONTRACT (one-time, gates the entire buy path)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the single contract address allowed to receive BB from the
     *         official pair. Can ONLY be called once. After set, no admin
     *         function exists to change it — the buy gate is permanently
     *         bound to this address.
     * @dev    Use a Gnosis Safe multisig as the deployer when calling this.
     */
    function setStakingContract(address contract_) external onlyOwner {
        if (stakingContract != address(0)) revert StakingContractAlreadySet();
        if (contract_ == address(0)) revert ZeroAddress();
        if (contract_.code.length == 0) revert NotAContract();
        stakingContract = contract_;
        emit StakingContractSet(contract_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // WHITELIST MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    function setWhitelist(address account, bool status) external onlyOwner {
        if (whitelistLocked) revert WhitelistIsLocked();
        if (account == address(0)) revert ZeroAddress();
        isWhitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    function setWhitelistBatch(address[] calldata accounts, bool status) external onlyOwner {
        if (whitelistLocked) revert WhitelistIsLocked();
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ) {
            address acct = accounts[i];
            if (acct == address(0)) revert ZeroAddress();
            isWhitelisted[acct] = status;
            emit WhitelistUpdated(acct, status);
            unchecked { ++i; }
        }
    }

    function lockWhitelist() external onlyOwner {
        whitelistLocked = true;
        emit WhitelistLockedForever();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TRADING TOGGLE (one-way: off → on)
    // ═══════════════════════════════════════════════════════════════════════

    function enableTrading() external onlyOwner {
        if (tradingEnabled) revert TradingAlreadyEnabled();
        if (officialPair == address(0)) revert InvalidPair();
        tradingEnabled = true;
        tradingEnabledBlock = block.number;
        emit TradingEnabled(block.number);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // FLASHLOAN BLOCKLIST
    // ═══════════════════════════════════════════════════════════════════════

    function setFlashloanProvider(address provider, bool blocked) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        if (provider == officialPair) revert InvalidPair();
        if (provider.code.length == 0) revert NotAContract(); // token blocklist: contracts only
        isBlockedFlashloanProvider[provider] = blocked;
        emit FlashloanProviderUpdated(provider, blocked);
    }

    function setFlashloanProviderBatch(address[] calldata providers, bool blocked) external onlyOwner {
        uint256 len = providers.length;
        for (uint256 i = 0; i < len; ) {
            address p = providers[i];
            if (p == address(0)) revert ZeroAddress();
            if (p == officialPair) revert InvalidPair();
            isBlockedFlashloanProvider[p] = blocked;
            emit FlashloanProviderUpdated(p, blocked);
            unchecked { ++i; }
        }
    }


    // ═══════════════════════════════════════════════════════════════════════
    // OWNERSHIP — PERMANENTLY LOCKED
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Ownership transfer is NOT supported. Always reverts.
     * @dev Provided only for ABI compatibility — there is no way to change
     *      the owner after construction. The `owner` storage slot is
     *      `immutable` and cannot be modified at the EVM level.
     */
    function transferOwnership(address /* newOwner */) external pure {
        revert OwnershipLocked();
    }

    /**
     * @notice Ownership renouncement is NOT supported. Always reverts.
     * @dev The deployer retains ownership permanently to enable ongoing
     *      flashloan-provider blocklist additions as new attack vectors
     *      emerge. All other admin powers (pair, whitelist, sell rules)
     *      ARE permanently lockable via their respective lock functions.
     */
    function renounceOwnership() external pure {
        revert OwnershipLocked();
    }
}
