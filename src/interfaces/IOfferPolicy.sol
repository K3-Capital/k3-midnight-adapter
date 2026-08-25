// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";

interface IOfferPolicy {
    function acceptsOffer(Offer calldata offer) external view returns (bool);
    function policyEpoch() external view returns (uint64);
}
