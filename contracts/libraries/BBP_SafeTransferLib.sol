// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../interfaces/IERC20.sol";
import "./SafeERC20.sol";

/**
 * @title SafeTransferLib (thin adapter over OpenZeppelin SafeERC20 v5.4.0)
 * @notice This library is a backward-compatibility shim. All logic delegates to
 *         the EXACT OpenZeppelin v5.4.0 SafeERC20 implementation. It exists so
 *         existing call sites in the protocol can continue calling the
 *         address-based API (`USDT_TOKEN.safeTransferFrom(...)`) without a
 *         large refactor.
 *
 *         All transfer/approval safety guarantees come from OpenZeppelin:
 *           - Assembly-based low-level call (memory-safe)
 *           - Optional-return handling (tokens that return nothing on success)
 *           - SafeERC20FailedOperation revert on any failure
 *           - forceApprove handles USDT-style non-zero -> non-zero rejection
 *             by resetting to 0 then re-approving
 *
 *         Do NOT add new logic here — extend SafeERC20.sol directly if needed.
 */
library SafeTransferLib {
    using SafeERC20 for IERC20;

    /// @notice Wrapper-only helper for explicit pre-checks (allowance & balance).
    function _allowance(address token, address owner, address spender) internal view returns (uint256) {
        return IERC20(token).allowance(owner, spender);
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    /// @notice Reverts on failure. Handles tokens that return no value.
    function safeTransfer(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Reverts on failure. Handles tokens that return no value.
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    /// @notice Approve `spender` to spend `amount`. Uses OpenZeppelin's
    ///         `forceApprove`, which automatically falls back to a 0-reset
    ///         + re-approve sequence when a non-zero allowance is already set
    ///         (the classic USDT pattern).
    function safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).forceApprove(spender, amount);
    }
}
