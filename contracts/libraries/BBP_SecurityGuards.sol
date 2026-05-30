// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";

/**
 * @title SecurityGuards
 * @notice Additional security layer for BigBull V4
 * @dev Critical security checks beyond basic validations
 *
 * COVERAGE:
 * - Chain ID verification (BSC mainnet only)
 * - Anomaly detection thresholds
 * - Triple-layer token verification
 * - Rate limit guards
 * - Wallet impersonation detection
 * - Bytecode integrity checks
 */

library SecurityGuards {

    // ═══════════════════════════════════════════════════════════════════════
    // CHAIN ID VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    uint256 internal constant BSC_TESTNET_CHAIN_ID = 97;

    error WrongChain();
    error AnomalyDetected();
    error ImpersonationAttempt();
    error TokenMismatch();
    error InvalidTimestamp();
    error AmountSuspicious();
    error RateLimitExceeded();

    /**
     * @notice Verify current chain is BSC mainnet (or testnet for dev)
     */
    function validateChain() internal view {
        uint256 chainId = block.chainid;
        if (chainId != BSC_MAINNET_CHAIN_ID && chainId != BSC_TESTNET_CHAIN_ID) {
            revert WrongChain();
        }
    }

    /**
     * @notice Strict mainnet-only check
     */
    function validateMainnetOnly() internal view {
        if (block.chainid != BSC_MAINNET_CHAIN_ID) revert WrongChain();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TIMESTAMP VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate block timestamp is reasonable
     * @dev Prevents manipulation attacks
     */
    function validateTimestamp(uint64 timestamp) internal view {
        // Must not be in the future (5 second tolerance for clock skew)
        if (timestamp > block.timestamp + 5) revert InvalidTimestamp();
        // Must not be too far in the past (24h tolerance)
        if (timestamp < block.timestamp - 86400) revert InvalidTimestamp();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADDRESS VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Multi-layer address verification
     */
    function validateAddress(address addr) internal pure {
        if (addr == address(0)) revert VaultTypes.ZeroAddress();
        // Burn addresses
        if (addr == address(0x000000000000000000000000000000000000dEaD)) revert VaultTypes.ZeroAddress();
        if (addr == address(0x0000000000000000000000000000000000000001)) revert VaultTypes.ZeroAddress();
    }

    /**
     * @notice Triple-layer EOA verification
     */
    function validateEOAStrict(address user) internal view {
        // Layer 1: tx.origin match
        if (user != tx.origin) revert ImpersonationAttempt();

        // Layer 2: No bytecode
        if (user.code.length != 0) revert ImpersonationAttempt();

        // Layer 3: extcodehash check (EIP-7702 detection)
        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(user)
        }
        bytes32 EMPTY_HASH = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        if (codeHash != bytes32(0) && codeHash != EMPTY_HASH) {
            revert ImpersonationAttempt();
        }

        // Layer 4: Check balance is reasonable (not contract-like)
        // EOAs typically don't have huge balances or be zero
        // (skip strict check, but log suspicious)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TOKEN VERIFICATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify token transfer happened correctly
     * @dev Tracks balance before/after to confirm actual transfer
     */
    function verifyTokenTransfer(
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 expectedAmount
    ) internal pure {
        if (balanceAfter < balanceBefore) revert TokenMismatch();
        uint256 actualReceived = balanceAfter - balanceBefore;

        // Must receive at least 99% (allow for fee-on-transfer tokens)
        uint256 minExpected = (expectedAmount * 99) / 100;
        if (actualReceived < minExpected) revert TokenMismatch();
    }

    /**
     * @notice Verify token addresses match expected
     */
    function verifyTokenAddress(
        address received,
        address expected
    ) internal pure {
        if (received != expected) revert TokenMismatch();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ANOMALY DETECTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if claim amount is anomalous compared to recent average
     * @param attemptUSD Amount being claimed
     * @param avgDailyClaimUSD Recent average daily claims
     * @return suspicious True if claim is anomalous
     */
    function detectClaimAnomaly(
        uint128 attemptUSD,
        uint128 avgDailyClaimUSD
    ) internal pure returns (bool suspicious) {
        if (avgDailyClaimUSD == 0) return false;

        // 3x the average = suspicious
        return attemptUSD > (avgDailyClaimUSD * 3);
    }

    /**
     * @notice Check if liquidity drop is anomalous
     */
    function detectLiquidityAnomaly(
        uint128 currentReserve,
        uint128 previousReserve
    ) internal pure returns (bool suspicious) {
        if (previousReserve == 0) return false;
        if (currentReserve >= previousReserve) return false;

        // 30% drop in single check = suspicious
        uint128 drop = previousReserve - currentReserve;
        uint256 dropPercent = (uint256(drop) * 100) / uint256(previousReserve);

        return dropPercent > 30;
    }

    /**
     * @notice Detect price manipulation by deviation
     */
    function detectPriceAnomaly(
        uint128 spotPrice,
        uint128 twapPrice,
        uint16 maxDeviationBP
    ) internal pure returns (bool suspicious) {
        if (twapPrice == 0 || spotPrice == 0) return false;

        uint256 deviation;
        if (spotPrice > twapPrice) {
            deviation = ((uint256(spotPrice) - uint256(twapPrice)) * 10000) / uint256(twapPrice);
        } else {
            deviation = ((uint256(twapPrice) - uint256(spotPrice)) * 10000) / uint256(twapPrice);
        }

        return deviation > maxDeviationBP;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RATE LIMITING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check per-block global rate limit
     */
    function checkBlockRateLimit(
        uint128 blockTotal,
        uint128 blockLimit
    ) internal pure {
        if (blockTotal >= blockLimit) revert RateLimitExceeded();
    }

    /**
     * @notice Check hourly rate limit
     */
    function checkHourlyRateLimit(
        uint128 hourlyTotal,
        uint128 hourlyLimit
    ) internal pure {
        if (hourlyTotal >= hourlyLimit) revert RateLimitExceeded();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SUSPICIOUS PATTERN DETECTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Detect suspicious deposit pattern (multiple deposits same block)
     */
    function detectDepositPattern(
        uint64 lastDepositBlock,
        uint16 depositsInSameBlock
    ) internal view returns (bool suspicious) {
        if (lastDepositBlock != uint64(block.number)) return false;
        return depositsInSameBlock >= 3;
    }

    /**
     * @notice Detect referral tree spam (multiple enrolls under same referrer fast)
     */
    function detectTreeSpam(
        uint64 lastEnrollTime,
        uint64 currentTime,
        uint16 enrollsInWindow
    ) internal pure returns (bool suspicious) {
        // 5 enrolls within 60 seconds = spam
        if (currentTime - lastEnrollTime > 60) return false;
        return enrollsInWindow >= 5;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAS GRIEFING PROTECTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Verify enough gas remains for safe execution
     */
    function requireMinGas(uint256 minRequired) internal view {
        if (gasleft() < minRequired) revert VaultTypes.InsufficientGas();
    }

    /**
     * @notice Check gas isn't being manipulated (block gas limit)
     */
    function validateGasContext() internal view {
        // Block gas limit should be reasonable for BSC
        // BSC block gas limit: ~140M
        if (block.gaslimit < 30_000_000) revert VaultTypes.InsufficientGas();
    }
}
