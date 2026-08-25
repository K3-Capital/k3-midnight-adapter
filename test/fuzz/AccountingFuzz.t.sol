// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {MarketAccounting} from "../../src/types/AdapterTypes.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {BlueMidnightAdapterAccountingTest} from "../unit/BlueMidnightAdapterAccounting.t.sol";

/// @notice Stateful operation-sequence coverage for scalar conservative accounting.
contract AccountingFuzzStatefulTest is BlueMidnightAdapterAccountingTest {
    function testFuzzOperationSequence(uint256 seed, uint8 length) public {
        length = uint8(bound(length, 4, 24));
        uint256 previousNav = adapter.realAssets();

        for (uint256 i; i < length; ++i) {
            uint256 operation = uint256(keccak256(abi.encode(seed, i))) % 4;
            uint256 credit = adapter.accounting().trackedCredit;
            if (operation == 0 || credit == 0) {
                uint256 assets = bound(uint256(keccak256(abi.encode(seed, i, "assets"))), 1, 1_000);
                uint256 units = bound(uint256(keccak256(abi.encode(seed, i, "units"))), 1, 1_000);
                midnight.takeMakerBuy(adapter, midnightId, midnightMarket, assets, units, units % 7);
            } else if (operation == 1) {
                uint256 impaired = bound(uint256(keccak256(abi.encode(seed, i, "impair"))), 0, credit);
                midnight.setPosition(midnightId, uint128(impaired), 0);
                midnight.setPosition(IdLib.toId(midnightMarket), uint128(impaired), 0);
            } else {
                uint256 available = midnight.credit(midnightId);
                if (available == 0) continue;
                uint256 units =
                    bound(uint256(keccak256(abi.encode(seed, i, "sell"))), 1, available < credit ? available : credit);
                midnight.takeMakerSell(adapter, midnightId, midnightMarket, units, units, 0);
            }

            uint256 nav = adapter.realAssets();
            MarketAccounting memory state = adapter.accounting();
            assertLe(
                nav,
                adapter.expectedSupplyAssets() + state.netMaturityClaim + state.trackedCredit
                    + token.balanceOf(address(adapter))
            );
            assertLe(state.bookValue, state.netMaturityClaim);
            assertLe(state.trackedCredit, type(uint128).max);
            previousNav = nav;
        }
        assertGe(previousNav, 0);
    }
}
