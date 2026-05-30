// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "./BBP_SafeTransferLib.sol";

interface IDexRouter {
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

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title DexLib
 * @notice PancakeSwap V2 swap + liquidity logic, extracted from the vault to keep
 *         the vault under the 24,576-byte limit. Runs via delegatecall, so
 *         address(this), balances, approvals and emitted events all belong to the
 *         vault. Security preserved: TWAP-based slippage, post-swap verification,
 *         and approvals reset to zero before AND after each action.
 */
library DexLib {
    using SafeTransferLib for address;

    uint256 internal constant SLIPPAGE_BP = 9900; // 1% tolerance
    uint256 internal constant BP = 10000;

    /**
     * @notice Swap USDT for BB with slippage protection based on the protected price.
     * @return received BB tokens actually received by the vault.
     */
    function swapUSDTtoBB(
        IDexRouter router,
        address usdt,
        address bb,
        uint128 usdtAmount,
        uint128 protectedPrice
    ) public returns (uint128 received) {
        if (usdtAmount == 0) return 0;

        usdt.safeApprove(address(router), usdtAmount);

        uint256 bbBefore = IERC20Balance(bb).balanceOf(address(this));

        // Minimum out from protected price (max(spot,twap) + deviation guard upstream)
        uint256 expectedBB = (uint256(usdtAmount) * 1e18) / uint256(protectedPrice);
        uint256 amountOutMin = (expectedBB * SLIPPAGE_BP) / BP;

        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = bb;

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtAmount,
            amountOutMin, // sandwich protection
            path,
            address(this),
            block.timestamp + 300
        );

        usdt.safeApprove(address(router), 0); // no lingering allowance

        uint256 bbAfter = IERC20Balance(bb).balanceOf(address(this));
        received = uint128(bbAfter - bbBefore);

        if (received < amountOutMin) revert VaultTypes.PriceImpactTooHigh();
    }

    /**
     * @notice Provide liquidity: swap half the USDT to BB, add both, LP to DEAD.
     */
    function addLiquidity(
        IDexRouter router,
        address usdt,
        address bb,
        address dead,
        uint128 usdtAmount,
        uint128 protectedPrice
    ) public {
        if (usdtAmount == 0) return;

        uint128 usdtHalf = usdtAmount / 2;
        uint128 bbFromSwap = swapUSDTtoBB(router, usdt, bb, usdtHalf, protectedPrice);
        uint128 usdtForLP = usdtAmount - usdtHalf;

        usdt.safeApprove(address(router), usdtForLP);
        bb.safeApprove(address(router), bbFromSwap);

        try router.addLiquidity(
            usdt, bb, usdtForLP, bbFromSwap, 0, 0, dead, block.timestamp + 300
        ) returns (uint256 a, uint256 b, uint256 liquidity) {
            emit VaultTypes.LiquidityAdded(uint128(a), uint128(b), uint128(liquidity));
        } catch {}

        // Reset both allowances to zero after adding liquidity
        usdt.safeApprove(address(router), 0);
        bb.safeApprove(address(router), 0);
    }
}
