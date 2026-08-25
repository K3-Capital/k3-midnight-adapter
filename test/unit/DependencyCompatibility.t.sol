// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {IAdapter} from "vault-v2/interfaces/IAdapter.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IBlueMidnightAdapter} from "../../src/interfaces/IBlueMidnightAdapter.sol";
import {IOfferPolicy} from "../../src/interfaces/IOfferPolicy.sol";
import {BlueMarketConfig} from "../../src/types/AdapterTypes.sol";

/// @notice Compile-time smoke test: the pinned upstream type graph is jointly usable.
contract DependencyCompatibilityTest is Test {
    function testPinnedInterfacesCompileTogether() external pure {
        // Referencing each type forces Foundry to compile all pinned interface imports.
        IMidnight midnight;
        IAdapter adapter;
        IMorpho blue;
        IBlueMidnightAdapter localAdapter;
        IOfferPolicy policy;
        Market memory midnightMarket;
        Offer memory offer;
        MarketParams memory blueMarket;
        BlueMarketConfig memory config;
        midnight;
        adapter;
        blue;
        localAdapter;
        policy;
        midnightMarket;
        offer;
        blueMarket;
        config;
        assert(true);
    }
}
