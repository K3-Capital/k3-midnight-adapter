// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Id, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {BlueMidnightAdapterAccountingTest} from "../unit/BlueMidnightAdapterAccounting.t.sol";

/// @notice Stateful operation-sequence coverage with an oracle built only from mock protocol state.
contract AccountingFuzzStatefulTest is BlueMidnightAdapterAccountingTest {
    using MarketParamsLib for MarketParams;

    function testFuzzOperationSequence(uint256 seed, uint8 length) public {
        length = uint8(bound(length, 4, 24));

        for (uint256 i; i < length; ++i) {
            uint256 operation = uint256(keccak256(abi.encode(seed, i))) % 4;
            uint256 available = midnight.credit(midnightId);
            if (operation == 0 || available == 0) {
                uint256 assets = bound(uint256(keccak256(abi.encode(seed, i, "assets"))), 0, 1_000);
                uint256 units = bound(uint256(keccak256(abi.encode(seed, i, "units"))), 1, 1_000);
                uint256 fee = units % 7;
                midnight.takeMakerBuy(adapter, midnightId, midnightMarket, assets, units, fee);
            } else if (operation == 1) {
                uint256 impaired = bound(uint256(keccak256(abi.encode(seed, i, "impair"))), 0, available);
                midnight.setPosition(midnightId, uint128(impaired), 0);
                midnight.setPosition(IdLib.toId(midnightMarket), uint128(impaired), 0);
            } else if (operation == 2) {
                uint256 units = bound(uint256(keccak256(abi.encode(seed, i, "repay"))), 1, available);
                token.mint(address(midnight), units);
                midnight.setPosition(midnightId, uint128(available), midnight.pendingFee(midnightId));
                midnight.setPosition(IdLib.toId(midnightMarket), uint128(available), midnight.pendingFee(midnightId));
                adapter.collectRepayment(units);
            } else {
                uint256 trackedAvailable = available;
                uint256 units = bound(uint256(keccak256(abi.encode(seed, i, "sell"))), 1, trackedAvailable);
                midnight.takeMakerSell(adapter, midnightId, midnightMarket, units, units, 0);
            }

            // Independent oracle: Blue supply is read from the mock market, while the Midnight
            // claim is read from the mock protocol position. No adapter accounting fields enter it.
            uint256 protocolClaim = uint256(midnight.credit(midnightId)) + midnight.pendingFee(midnightId);
            uint256 upperBound = _externalBlueAssets() + token.balanceOf(address(adapter)) + protocolClaim;
            assertLe(adapter.realAssets(), upperBound);
        }
    }

    function _externalBlueAssets() internal view returns (uint256) {
        Id blueId = blueMarket.id();
        uint256 totalSupplyAssets = morpho.balances(Id.unwrap(blueId), 0);
        uint256 totalSupplyShares = morpho.balances(Id.unwrap(blueId), 1);
        if (totalSupplyShares == 0) return 0;
        return morpho.shares(Id.unwrap(blueId)) * totalSupplyAssets / totalSupplyShares;
    }
}
