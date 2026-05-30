// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title ReentrancyGuard
 * @notice Gas-optimized reentrancy protection with multiple layers
 * @dev Provides:
 *      1. nonReentrant - standard reentrancy lock
 *      2. processingLock - cross-function locking per user
 *      3. onePerBlock - same-block action prevention
 */

abstract contract ReentrancyGuard {

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    // Cross-function lock (per user)
    mapping(address => bool) private _processing;

    // Same-block action tracking (per user)
    mapping(address => uint256) private _lastActionBlock;

    error ReentrancyDetected();
    error AlreadyProcessing();
    error SameBlockBlocked();

    constructor() {
        _status = _NOT_ENTERED;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LAYER 1: Standard Reentrancy Guard
    // ═══════════════════════════════════════════════════════════════════════

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyDetected();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LAYER 2: Cross-Function Lock (Per User)
    // ═══════════════════════════════════════════════════════════════════════

    modifier processingLock(address user) {
        if (_processing[user]) revert AlreadyProcessing();
        _processing[user] = true;
        _;
        _processing[user] = false;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LAYER 3: Same-Block Protection (Per User)
    // ═══════════════════════════════════════════════════════════════════════

    modifier onePerBlock(address user) {
        if (_lastActionBlock[user] == block.number) revert SameBlockBlocked();
        _lastActionBlock[user] = block.number;
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function isProcessing(address user) external view returns (bool) {
        return _processing[user];
    }

    function getLastActionBlock(address user) external view returns (uint256) {
        return _lastActionBlock[user];
    }

    function getReentrancyStatus() external view returns (uint256) {
        return _status;
    }
}
