// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {Offer} from "midnight/interfaces/IMidnight.sol";

/// @dev Shared data shapes only; behavior is intentionally deferred to later stack layers.
struct BlueMarketConfig {
    MarketParams market;
    bytes32 marketId;
}

struct MarketAccounting {
    uint128 bookValue;
    uint128 netMaturityClaim;
    uint128 trackedCredit;
    uint40 lastCheckpoint;
    bool active;
}

struct MarketEconomicPolicy {
    uint24 maxBuyTick;
    uint24 minSellTick;
    uint40 maxTenor;
    uint40 maxExpiryHorizon;
    uint32 maxContinuousFeePerSecondWad;
    uint64 maxSettlementFeeWad;
    bool configured;
}

struct SafeExit {
    Offer offer;
    bytes ratifierData;
    uint256 units;
}

struct SafeExitPayload {
    uint8 version;
    SafeExit[] exits;
    uint256 maxLossAssets;
}
