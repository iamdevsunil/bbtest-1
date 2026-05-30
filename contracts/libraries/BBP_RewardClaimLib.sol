// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";

/**
 * @title RewardClaimLib
 * @notice External (delegatecall'd) library that unlocks Performance Reward grants
 *         into the user's pendingExpansion bucket using a single full-release model.
 *
 * @dev Behaviour (per team-network spec refinement):
 *      - Each achieved tier is queued as one RewardGrant (FIFO, advanced via head pointer).
 *      - The grant must "ripen" for REWARD_HOLD_DELAY (24 hours) after the achievement
 *        before it can be claimed — replacing the earlier 4-installments × 6-hour scheme.
 *      - After ripening, a single call to claimReward() moves the FULL totalUSD into
 *        pendingExpansion (no fractional tranches) and advances the queue head.
 *      - claimReward() has its own cooldown (REWARD_CLAIM_COOLDOWN, 24h) separate from the
 *        regular claim cooldown — enforced by the vault via lastRewardClaimAt.
 *      - The user then runs claim() to receive BB tokens; pendingExpansion drains under the
 *        normal 25%-of-cap daily limit, so a large reward naturally pays out across days if
 *        it exceeds the day's cap — keeping price-impact bounded.
 *      - O(1) per call. No loops over queue length: only the head grant is inspected.
 */
library RewardClaimLib {
    /// @notice Time the user must wait after an achievement before the grant can be claimed.
    uint64 internal constant REWARD_HOLD_DELAY = 24 hours;

    event RewardReleased(address indexed user, uint8 tier, uint128 amountUSD);

    /**
     * @notice Release the next queued reward (if ripe) into pendingExpansion.
     * @param queue The user's reward queue (FIFO of RewardGrant).
     * @param u    The user's account storage.
     * @param head Current head pointer into the queue.
     * @param nowT block.timestamp passed in for gas efficiency.
     * @return newHead Updated head pointer (advances when a grant is fully released).
     * @return amount  USD amount released into pendingExpansion this call.
     */
    function claimReward(
        VaultTypes.RewardGrant[] storage queue,
        VaultTypes.UserAccount storage u,
        uint256 head,
        uint64 nowT
    ) public returns (uint256 newHead, uint128 amount) {
        if (head >= queue.length) revert VaultTypes.NoRewardToClaim();

        VaultTypes.RewardGrant storage g = queue[head];

        // 24-hour hold from the achievement (or last release event) must have elapsed.
        if (nowT < g.lastEventTime + REWARD_HOLD_DELAY) revert VaultTypes.RewardTimerActive();

        // Full single release — the daily cap protection is applied at claim() time when
        // pendingExpansion drains. Keeping this routine to a single release per call also
        // makes it O(1) and trivial to audit.
        amount = g.totalUSD;
        g.partsReleased = 1;            // 0=unreleased, 1=released (single-tranche model)
        g.lastEventTime = nowT;          // record release time
        u.pendingExpansion += amount;

        emit RewardReleased(msg.sender, g.tier, amount);

        newHead = head + 1;              // advance past the fully-released grant
    }
}
