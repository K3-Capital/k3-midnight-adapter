// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";

contract CallbackVaultMock {
    address public immutable token;

    constructor(address asset_) {
        token = asset_;
    }

    function asset() external view returns (address) {
        return token;
    }

    function curator() external view returns (address) {
        return msg.sender;
    }

    function isSentinel(address) external pure returns (bool) {
        return false;
    }
}

contract CallbackTokenMock {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract BlueMidnightAdapterCallbacksTest is Test {
    BlueMidnightAdapter adapter;
    CallbackVaultMock vault;

    function setUp() public {
        CallbackTokenMock token = new CallbackTokenMock();
        vault = new CallbackVaultMock(address(token));
        Market memory midnightMarket = Market({
            chainId: block.chainid,
            midnight: address(0x200),
            loanToken: address(token),
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        MarketParams memory blueMarket = MarketParams(address(token), address(1), address(2), address(3), 0);
        MarketEconomicPolicy memory policy = MarketEconomicPolicy(1_000, 0, 20 days);
        adapter = new BlueMidnightAdapter(
            address(vault),
            blueMarket,
            address(0x200),
            address(0x300),
            address(0x400),
            midnightMarket,
            policy,
            address(this)
        );
    }

    function testBuyRejectsNonMidnightCaller() public {
        Market memory market;
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.onBuy(bytes32(0), market, 1, 1, 0, address(adapter), "");
    }

    function testSellPinsSellerAndReceiver() public {
        Market memory market;
        vm.prank(address(0x200));
        vm.expectRevert(BlueMidnightAdapter.InvalidReceiver.selector);
        adapter.onSell(bytes32(0), market, 1, 1, 0, address(0x123), address(adapter), "");
    }
}
