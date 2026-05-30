// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./BBP_Constants.sol";
import "./BBP_Types.sol";

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/**
 * @title PriceOracle
 * @notice DeFi-grade price oracle with hardcoded BB/USDT pair
 * @dev Critical security features:
 *      - Pair address IMMUTABLE (cannot be changed)
 *      - Token addresses IMMUTABLE
 *      - Reads DIRECTLY from pair contract (NO router)
 *      - NO multi-hop routing possible
 *      - NO other pairs influence price
 *      - TWAP for manipulation resistance
 *      - max(spot, twap) for vault-favorable pricing
 */

abstract contract PriceOracle {

    // ═══════════════════════════════════════════════════════════════════════
    // IMMUTABLE PAIR CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The ONLY pair contract this oracle reads from
    address public immutable BIB_USDT_PAIR;
    address public immutable BIB_TOKEN;
    address public immutable USDT_TOKEN;
    bool public immutable BIB_IS_TOKEN0;

    // ═══════════════════════════════════════════════════════════════════════
    // TWAP STATE
    // ═══════════════════════════════════════════════════════════════════════

    uint256 private _lastCumulativePrice;
    uint64 private _lastUpdateTime;
    uint128 private _cachedTWAP;
    bool private _twapInitialized;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event TWAPUpdated(uint128 newTWAP, uint64 timestamp);

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR (Validates pair correctness)
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        address pairAddress,
        address bibAddress,
        address usdtAddress
    ) {
        // Validate non-zero
        if (pairAddress == address(0)) revert VaultTypes.ZeroAddress();
        if (bibAddress == address(0)) revert VaultTypes.ZeroAddress();
        if (usdtAddress == address(0)) revert VaultTypes.ZeroAddress();

        // Tokens must be different
        if (bibAddress == usdtAddress) revert VaultTypes.InvalidPair();

        // Validate pair contains EXACTLY these tokens
        IPancakePair pair = IPancakePair(pairAddress);
        address t0 = pair.token0();
        address t1 = pair.token1();

        bool validPair = (t0 == bibAddress && t1 == usdtAddress) ||
                        (t0 == usdtAddress && t1 == bibAddress);
        if (!validPair) revert VaultTypes.InvalidPair();

        // Validate token decimals (both must be 18 for our math)
        if (IERC20Decimals(bibAddress).decimals() != 18) revert VaultTypes.InvalidDecimals();
        if (IERC20Decimals(usdtAddress).decimals() != 18) revert VaultTypes.InvalidDecimals();

        // Store immutables
        BIB_USDT_PAIR = pairAddress;
        BIB_TOKEN = bibAddress;
        USDT_TOKEN = usdtAddress;
        BIB_IS_TOKEN0 = (t0 == bibAddress);

        _lastUpdateTime = uint64(block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SPOT PRICE (Direct from pair reserves)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Get spot price of BB in USDT (18 decimals)
     * @dev Reads DIRECTLY from immutable pair - no router involvement
     * @return price USDT per 1 BB token (18 decimals)
     */
    function getSpotPrice() public view returns (uint128 price) {
        (uint112 r0, uint112 r1, ) = IPancakePair(BIB_USDT_PAIR).getReserves();

        uint256 bibReserve;
        uint256 usdtReserve;

        if (BIB_IS_TOKEN0) {
            bibReserve = uint256(r0);
            usdtReserve = uint256(r1);
        } else {
            bibReserve = uint256(r1);
            usdtReserve = uint256(r0);
        }

        if (bibReserve == 0 || usdtReserve == 0) revert VaultTypes.LiquidityTooLow();
        if (usdtReserve < VaultConstants.MIN_LIQUIDITY) revert VaultTypes.LiquidityTooLow();

        // price = USDT per 1 BB (18 decimals)
        price = uint128((usdtReserve * 1e18) / bibReserve);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TWAP CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Update and return TWAP price
     * @dev Updates cumulative price tracking, returns time-weighted average
     */
    function _updateAndGetTWAP() internal returns (uint128 twap) {
        IPancakePair pair = IPancakePair(BIB_USDT_PAIR);

        // Get current cumulative price (Pancake V2 standard)
        uint256 currentCumulative = BIB_IS_TOKEN0
            ? pair.price0CumulativeLast()
            : pair.price1CumulativeLast();

        uint64 currentTime = uint64(block.timestamp);
        uint64 timeElapsed = currentTime - _lastUpdateTime;

        if (!_twapInitialized) {
            // First call - initialize state
            _lastCumulativePrice = currentCumulative;
            _lastUpdateTime = currentTime;
            _twapInitialized = true;
            // Use spot as initial TWAP
            _cachedTWAP = getSpotPrice();
            return _cachedTWAP;
        }

        if (timeElapsed >= VaultConstants.TWAP_WINDOW) {
            // Sufficient time passed - calculate new TWAP
            uint256 priceDiff = currentCumulative - _lastCumulativePrice;
            uint256 avgPrice = priceDiff / timeElapsed;

            // Convert from FixedPoint (Q112) to 18 decimals
            // Pancake uses Q112.112 format, we need to scale appropriately
            twap = uint128((avgPrice * 1e18) >> 112);

            _lastCumulativePrice = currentCumulative;
            _lastUpdateTime = currentTime;
            _cachedTWAP = twap;

            emit TWAPUpdated(twap, currentTime);
        } else {
            // Not enough time - use cached
            twap = _cachedTWAP;
        }
    }

    /**
     * @notice Get cached TWAP without updating
     */
    function getTWAP() public view returns (uint128) {
        if (!_twapInitialized) {
            // Return spot if not initialized
            return _safeTrySpot();
        }
        return _cachedTWAP;
    }

    /**
     * @notice Get protected price - max(spot, twap)
     * @dev Vault-favorable: uses HIGHER price for payouts
     *      Attackers cannot benefit from price manipulation
     */
    function _getProtectedPrice() internal returns (uint128) {
        uint128 spot = getSpotPrice();
        uint128 twap = _updateAndGetTWAP();

        // STALE-ORACLE GUARD: if the oracle has not been touched for more than
        // MAX_ORACLE_AGE (2h), the cumulative-price reading may have drifted
        // far from current reality even if a brand-new TWAP just got computed.
        // Block this access. After the next access the timestamps will be
        // fresh again. Only applies after the oracle has been initialised.
        if (_twapInitialized) {
            uint64 age;
            unchecked { age = uint64(block.timestamp) - _lastUpdateTime; }
            if (age > VaultConstants.MAX_ORACLE_AGE) {
                revert VaultTypes.OracleStale();
            }
        }

        // DEVIATION GUARD: if spot is being actively manipulated away from TWAP
        // beyond the allowed band, REVERT. This stops anyone from staking or
        // claiming while a flash-pump / flash-crash is in progress — the
        // manipulated state never produces a credited position.
        if (_twapInitialized && twap != 0 && spot != 0) {
            uint256 deviation;
            if (spot > twap) {
                deviation = ((uint256(spot) - uint256(twap)) * VaultConstants.PERC_DIVIDER) / twap;
            } else {
                deviation = ((uint256(twap) - uint256(spot)) * VaultConstants.PERC_DIVIDER) / twap;
            }
            if (deviation > VaultConstants.MAX_PRICE_DEVIATION_BP) {
                revert VaultTypes.TWAPDeviationTooHigh();
            }
        }

        // Vault-favorable: max ensures user gets FEWER tokens at manipulated price
        return spot > twap ? spot : twap;
    }

    /**
     * @notice Get protected price (view only)
     */
    function getProtectedPriceView() external view returns (uint128) {
        uint128 spot = getSpotPrice();
        uint128 twap = getTWAP();
        return spot > twap ? spot : twap;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PRICE VALIDATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate that spot price hasn't deviated too much from TWAP
     * @dev Reverts if deviation > MAX_PRICE_DEVIATION_BP (5%)
     */
    function _validatePriceDeviation() internal view {
        if (!_twapInitialized) return; // Skip on first calls

        uint128 spot = getSpotPrice();
        uint128 twap = _cachedTWAP;

        if (twap == 0 || spot == 0) return;

        uint256 deviation;
        if (spot > twap) {
            deviation = ((spot - twap) * VaultConstants.PERC_DIVIDER) / twap;
        } else {
            deviation = ((twap - spot) * VaultConstants.PERC_DIVIDER) / twap;
        }

        if (deviation > VaultConstants.MAX_PRICE_DEVIATION_BP) {
            revert VaultTypes.TWAPDeviationTooHigh();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _safeTrySpot() private view returns (uint128) {
        try this.getSpotPrice() returns (uint128 p) {
            return p;
        } catch {
            return 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function getReserves() external view returns (uint128 bibReserve, uint128 usdtReserve) {
        (uint112 r0, uint112 r1, ) = IPancakePair(BIB_USDT_PAIR).getReserves();
        if (BIB_IS_TOKEN0) {
            return (uint128(r0), uint128(r1));
        } else {
            return (uint128(r1), uint128(r0));
        }
    }

    function isPriceSafe() external view returns (bool) {
        if (!_twapInitialized) return true;

        try this.getSpotPrice() returns (uint128 spot) {
            if (spot == 0) return false;

            uint128 twap = _cachedTWAP;
            if (twap == 0) return false;

            uint256 deviation;
            if (spot > twap) {
                deviation = ((spot - twap) * VaultConstants.PERC_DIVIDER) / twap;
            } else {
                deviation = ((twap - spot) * VaultConstants.PERC_DIVIDER) / twap;
            }

            return deviation <= VaultConstants.MAX_PRICE_DEVIATION_BP;
        } catch {
            return false;
        }
    }
}
