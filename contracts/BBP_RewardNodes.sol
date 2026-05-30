// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title BBRewardNodesConfig
 * @notice Static configuration of the 20 protocol-treasury wallets that receive
 *         equal shares of treasury-routed payouts (the BB-11 skipped-income
 *         fallback). Replaces the previous single `daoGovernor` wallet.
 *
 *         PRIVATE BY DESIGN. Addresses live in a separate file so they never
 *         appear in any public getter on the deployed vault. Edit this file
 *         BEFORE compile to set live addresses; do not commit the filled-in
 *         version to a public repository.
 *
 *         Naming follows DeFi protocol treasury convention:
 *           - 16 generic Reward Node wallets (NODE_0 .. NODE_15)
 *           -  1 protocolReserve   (operational reserve)
 *           -  1 insuranceFund     (coverage / shortfall buffer)
 *           -  1 bugBountyVault    (security bounty payouts)
 *           -  1 ecosystemFund     (integrations + grants)
 *
 *         Each wallet receives exactly 1/20 of any treasury-routed amount.
 */
library BBRewardNodesConfig {

    // ─── 16 Reward Node wallets (placeholders — replace before deploy) ──
    address internal constant NODE_0  = 0x0000000000000000000000000000000000001001;
    address internal constant NODE_1  = 0x0000000000000000000000000000000000001002;
    address internal constant NODE_2  = 0x0000000000000000000000000000000000001003;
    address internal constant NODE_3  = 0x0000000000000000000000000000000000001004;
    address internal constant NODE_4  = 0x0000000000000000000000000000000000001005;
    address internal constant NODE_5  = 0x0000000000000000000000000000000000001006;
    address internal constant NODE_6  = 0x0000000000000000000000000000000000001007;
    address internal constant NODE_7  = 0x0000000000000000000000000000000000001008;
    address internal constant NODE_8  = 0x0000000000000000000000000000000000001009;
    address internal constant NODE_9  = 0x0000000000000000000000000000000000001010;
    address internal constant NODE_10 = 0x0000000000000000000000000000000000001011;
    address internal constant NODE_11 = 0x0000000000000000000000000000000000001012;
    address internal constant NODE_12 = 0x0000000000000000000000000000000000001013;
    address internal constant NODE_13 = 0x0000000000000000000000000000000000001014;
    address internal constant NODE_14 = 0x0000000000000000000000000000000000001015;
    address internal constant NODE_15 = 0x0000000000000000000000000000000000001016;

    // ─── 4 DeFi-named treasury wallets ──────────────────────────────────
    address internal constant PROTOCOL_RESERVE  = 0x0000000000000000000000000000000000001017;
    address internal constant INSURANCE_FUND    = 0x0000000000000000000000000000000000001018;
    address internal constant BUG_BOUNTY_VAULT  = 0x0000000000000000000000000000000000001019;
    address internal constant ECOSYSTEM_FUND    = 0x0000000000000000000000000000000000001020;

    /// @notice Returns the 20 treasury wallets in fixed order. Used internally
    ///         by the vault during construction; not exposed via any public
    ///         getter on the deployed contract.
    function getNodes() internal pure returns (address[20] memory nodes) {
        nodes[0]  = NODE_0;
        nodes[1]  = NODE_1;
        nodes[2]  = NODE_2;
        nodes[3]  = NODE_3;
        nodes[4]  = NODE_4;
        nodes[5]  = NODE_5;
        nodes[6]  = NODE_6;
        nodes[7]  = NODE_7;
        nodes[8]  = NODE_8;
        nodes[9]  = NODE_9;
        nodes[10] = NODE_10;
        nodes[11] = NODE_11;
        nodes[12] = NODE_12;
        nodes[13] = NODE_13;
        nodes[14] = NODE_14;
        nodes[15] = NODE_15;
        nodes[16] = PROTOCOL_RESERVE;
        nodes[17] = INSURANCE_FUND;
        nodes[18] = BUG_BOUNTY_VAULT;
        nodes[19] = ECOSYSTEM_FUND;
    }
}
