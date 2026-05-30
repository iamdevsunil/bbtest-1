// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../BBP_Types.sol";
import "../BBP_Constants.sol";

/**
 * @title AnomalyMonitor
 * @notice External (delegatecall'd) library encapsulating the claim-anomaly
 *         monitor + auto-pause trigger evaluation. Used by BigBullVault to keep
 *         the vault bytecode under the EIP-170 24,576-byte limit.
 *
 *         Two triggers:
 *           (1) single-claim ceiling — any single claim ≥ ceiling.
 *           (2) daily spike — claimedToday > dailyClaimSpikeMult × 7-day avg.
 *
 *         The library performs the day-rotation, 7-day running-average update,
 *         and accumulates the day's claim total. It returns a trigger code so
 *         the vault can locally auto-pause and emit its event (events stay in
 *         the vault for explorer attribution).
 */
library AnomalyMonitor {

    /// @notice Run the full anomaly check + state update for one claim.
    /// @param data    Storage ref to the vault's ClaimAnomalyData struct.
    /// @param claimUSD The claim amount being processed.
    /// @return trigger 0 = no anomaly, 1 = single-claim ceiling, 2 = daily spike.
    /// @return amount  Amount associated with the trigger (single-claim or daily total).
    function checkClaim(
        VaultTypes.ClaimAnomalyData storage data,
        uint128 claimUSD
    ) public returns (uint8 trigger, uint128 amount) {
        uint64 today = uint64(block.timestamp / VaultConstants.DAY);

        // Day rotation: fold yesterday into the running 7-day average
        if (today != data.claimAnomalyDay) {
            if (data.claimAnomalyDay != 0) {
                if (data.claimHistoryDays >= 7) {
                    // running approximation: remove avg before adding new day
                    data.claimHistorySum -= data.avgDailyClaimUSD;
                } else {
                    data.claimHistoryDays += 1;
                }
                data.claimHistorySum += data.claimedTodayUSD;
                data.avgDailyClaimUSD = data.claimHistorySum / data.claimHistoryDays;
            }
            data.claimAnomalyDay = today;
            data.claimedTodayUSD = 0;
        }

        // Trigger 1: single-claim ceiling
        if (claimUSD >= data.singleClaimCeilingUSD) {
            return (1, claimUSD);
        }

        // Accumulate today's total
        data.claimedTodayUSD += claimUSD;

        // Trigger 2: daily spike vs running 7-day average
        if (data.avgDailyClaimUSD > 0 && data.dailyClaimSpikeMult > 0) {
            uint256 threshold = uint256(data.avgDailyClaimUSD) * uint256(data.dailyClaimSpikeMult);
            if (data.claimedTodayUSD > threshold) {
                return (2, data.claimedTodayUSD);
            }
        }

        return (0, 0);
    }
}
