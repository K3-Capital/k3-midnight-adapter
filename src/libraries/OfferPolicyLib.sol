// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";

/// @notice Pure predicates for exact-market offer policy checks.
library OfferPolicyLib {
    function isExactMarket(
        Offer calldata offer,
        bytes32 expectedMarketHash,
        address expectedMidnight,
        address expectedAsset
    ) internal pure returns (bool) {
        return HashLib.hashMarket(offer.market) == expectedMarketHash && offer.market.midnight == expectedMidnight
            && offer.market.loanToken == expectedAsset;
    }
}
