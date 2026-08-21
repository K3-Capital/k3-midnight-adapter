// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";

/// @dev Policy hook reserved for Stage 2; this PR defines no production behavior.
interface IOfferPolicy {
    function acceptsOffer(Offer calldata offer) external view returns (bool);
}
