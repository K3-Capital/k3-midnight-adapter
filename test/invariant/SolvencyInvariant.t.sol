// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {ExitToken, ExitVault, ExitMorpho} from "../unit/BlueMidnightAdapterExit.t.sol";

contract SolvencyInvariantTest is Test {
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;
    BlueMidnightAdapter adapter;
    MarketParams market;

    function setUp() public {
        token = new ExitToken();
        vault = new ExitVault(address(token));
        morpho = new ExitMorpho(address(token));
        adapter = new BlueMidnightAdapter(address(vault), address(4), address(morpho), address(5));
        market = MarketParams(address(token), address(1), address(2), address(3), 0);
        bytes memory data = abi.encodeWithSelector(adapter.setBlueMarket.selector, market);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setBlueMarket(market);
    }

    function testSolvencyInvariantNoPhantomAssetsAfterAllocation() public {
        token.mint(address(vault), 100);
        vm.prank(address(vault));
        token.transfer(address(adapter), 100);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 100, bytes4(0), address(0));

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(adapter.realAssets(), adapter.expectedSupplyAssets());
    }
}
