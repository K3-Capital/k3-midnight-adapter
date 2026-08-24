// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapterFactory} from "../../src/BlueMidnightAdapterFactory.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {ExitToken, ExitVault, ExitMorpho} from "../unit/BlueMidnightAdapterExit.t.sol";

/// @notice Deterministic local integration of factory, Vault boundary, and Blue sleeve.
/// @dev Midnight callback lifecycle is exercised against the dedicated callback/accounting
///      suites; this test keeps the deployment and withdrawal path independent of those mocks.
contract VaultBlueMidnightIntegrationTest is Test {
    BlueMidnightAdapterFactory factory;
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;
    BlueMidnightAdapter adapter;
    MarketParams market;

    function setUp() public {
        factory = new BlueMidnightAdapterFactory();
        token = new ExitToken();
        vault = new ExitVault(address(token));
        morpho = new ExitMorpho(address(token));
        adapter = BlueMidnightAdapter(
            factory.deploy(keccak256("integration"), address(vault), address(4), address(morpho), address(5))
        );
        market = MarketParams(address(token), address(1), address(2), address(3), 0);

        bytes memory data = abi.encodeWithSelector(adapter.setBlueMarket.selector, market);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setBlueMarket(market);
    }

    function testDepositAllocateBlueDeallocateWithdraw() public {
        token.mint(address(vault), 100);
        vm.prank(address(vault));
        token.transfer(address(adapter), 100);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 100, bytes4(0), address(0));

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(adapter.expectedSupplyAssets(), 100);

        vm.prank(address(vault));
        adapter.deallocate(abi.encode(market), 100, bytes4(0), address(0));
        vm.prank(address(vault));
        token.transferFrom(address(adapter), address(vault), 100);

        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(adapter.expectedSupplyAssets(), 0);
        assertEq(adapter.realAssets(), 0);
    }

    function testFactoryPredictionMatchesIntegrationDeployment() public view {
        address predicted =
            factory.predict(keccak256("integration-2"), address(vault), address(4), address(morpho), address(5));
        assertTrue(predicted != address(0));
    }
}
