// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./../BBP_Types.sol";
import "./../BBP_Constants.sol";

/**
 * @title ValidationLib
 * @notice All security checks and validation logic
 * @dev Only enforces tx.origin == msg.sender so smart-account / multi-sig
 *      wallets (MetaMask Smart Account, Coinbase Smart Wallet, Trust Wallet AA,
 *      Safe, etc.) work normally. Blocks ONLY contract-to-contract calls into
 *      enroll/stake/claim — which is the actual attack vector (flash loan bots
 *      that try to mass-register fake users in a single transaction).
 */
library ValidationLib {

    // ═══════════════════════════════════════════════════════════════════════
    // EOA / CONTRACT CHECKS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Block contracts (incl. flash-loan attackers) from calling
     *         protocol-mutating functions. Modern wallets (Smart Account,
     *         AA, multi-sig) pass this check because tx.origin is still the
     *         user's EOA — even when their wallet delegates calls.
     */
    function validateEOA(address user) internal view {
        if (user != tx.origin) revert VaultTypes.NotEOA();
    }

    /**
     * @notice Validate an externally-provided address parameter (referrer,
     *         genesis, etc). Only check it isn't zero. Modern wallet contracts
     *         and smart wallets are valid users — do not block them.
     */
    function validateEOAExternal(address user) internal pure {
        if (user == address(0)) revert VaultTypes.ZeroAddress();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DEPOSIT VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateDepositAmount(uint128 amount) internal pure {
        if (amount < VaultConstants.MIN_DEPOSIT) revert VaultTypes.MinDepositNotMet();
        if (amount > VaultConstants.MAX_DEPOSIT) revert VaultTypes.MaxDepositExceeded();
        if (amount % 1e18 != 0) revert VaultTypes.InvalidAmount();
    }

    function validateDailyDepositLimit(
        uint64 lastDay,
        uint16 todayCount,
        uint64 currentTime
    ) internal pure returns (uint16 newCount, uint64 newDay) {
        uint64 today = currentTime / uint64(VaultConstants.DAY);
        if (lastDay != today) {
            newCount = 1;
            newDay = today;
        } else {
            if (todayCount >= VaultConstants.MAX_DAILY_DEPOSITS) {
                revert VaultTypes.DailyDepositLimitReached();
            }
            newCount = todayCount + 1;
            newDay = today;
        }
    }

    function validateStakeLimit(uint256 currentStakes, uint16 personalLimit) internal pure {
        if (currentStakes >= personalLimit) revert VaultTypes.LifetimeStakeLimitReached();
        if (currentStakes >= VaultConstants.MAX_STAKES) revert VaultTypes.LifetimeStakeLimitReached();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COOLDOWN VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateDepositCooldown(uint64 lastDeposit, uint64 currentTime) internal pure {
        if (lastDeposit > 0 && currentTime < lastDeposit + VaultConstants.DEPOSIT_COOLDOWN) {
            revert VaultTypes.CooldownActive();
        }
    }

    function validateEnrollGrace(uint64 enrolledAt, uint64 currentTime) internal pure {
        if (enrolledAt == 0) revert VaultTypes.NotEnrolled();
        if (currentTime < enrolledAt + VaultConstants.ENROLL_TO_DEPOSIT_GRACE) {
            revert VaultTypes.EnrollGraceNotMet();
        }
    }

    function validateReferrerGrace(uint64 referrerLastDeposit, uint64 currentTime) internal pure {
        if (referrerLastDeposit > 0 && currentTime < referrerLastDeposit + VaultConstants.REFERRER_FRESH_DEPOSIT_GRACE) {
            revert VaultTypes.ReferrerGraceNotMet();
        }
    }

    function validateFirstClaimLock(uint64 firstDepositAt, uint64 currentTime) internal pure {
        if (firstDepositAt == 0) revert VaultTypes.NotEnrolled();
        if (currentTime < firstDepositAt + VaultConstants.FIRST_CLAIM_LOCK) {
            revert VaultTypes.FirstClaimLocked();
        }
    }

    function validateClaimCooldown(uint64 lastClaim, uint64 currentTime) internal pure {
        if (lastClaim > 0 && currentTime < lastClaim + VaultConstants.CLAIM_COOLDOWN) {
            revert VaultTypes.ClaimCooldownActive();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ENROLLMENT VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateEnrollment(
        bool selfEnrolled,
        bool referrerEnrolled,
        address self,
        address referrer
    ) internal pure {
        if (selfEnrolled) revert VaultTypes.AlreadyEnrolled();
        if (!referrerEnrolled) revert VaultTypes.ReferrerNotEnrolled();
        if (self == referrer) revert VaultTypes.SelfReferral();
        if (referrer == address(0)) revert VaultTypes.ZeroAddress();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIM VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateMaxWithdraw(uint128 amountUSD) internal pure returns (uint128) {
        if (amountUSD > VaultConstants.MAX_WITHDRAW_USD) {
            return VaultConstants.MAX_WITHDRAW_USD;
        }
        return amountUSD;
    }

    function validateDailyClaimLimit(
        uint64 lastClaimDay,
        uint128 todayClaimed,
        uint128 currentCapUSD,
        uint64 currentTime
    ) internal pure returns (uint64 newDay, uint128 maxAllowed) {
        uint64 today = currentTime / uint64(VaultConstants.DAY);
        uint128 dailyLimit = uint128((uint256(currentCapUSD) *
                                      VaultConstants.DAILY_CLAIM_CAP_BP) /
                                      VaultConstants.PERC_DIVIDER);
        if (lastClaimDay != today) {
            return (today, dailyLimit);
        } else {
            if (todayClaimed >= dailyLimit) revert VaultTypes.DailyClaimLimitReached();
            return (today, dailyLimit - todayClaimed);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LIQUIDITY VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateLiquidity(uint128 usdtReserve) internal pure {
        if (usdtReserve < VaultConstants.MIN_LIQUIDITY) revert VaultTypes.LiquidityTooLow();
    }

    function validatePostSwapLiquidity(uint128 usdtReserve) internal pure {
        if (usdtReserve < VaultConstants.MIN_LIQUIDITY_POST_SWAP) revert VaultTypes.LiquidityTooLow();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VAULT BALANCE VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    function validateVaultBalance(uint256 vaultBalance, uint128 needed) internal pure {
        if (vaultBalance < needed) revert VaultTypes.InsufficientVaultBalance();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GAS CHECK
    // ═══════════════════════════════════════════════════════════════════════

    function validateGas() internal view {
        if (gasleft() < VaultConstants.MIN_GAS_REQUIRED) revert VaultTypes.InsufficientGas();
    }
}
