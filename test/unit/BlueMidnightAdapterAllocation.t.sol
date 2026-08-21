// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";

contract AllocationToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract AllocationVault {
    address public immutable token;
    address public curator;

    constructor(address _token) {
        token = _token;
        curator = msg.sender;
    }

    function asset() external view returns (address) {
        return token;
    }

    function isSentinel(address) external pure returns (bool) {
        return false;
    }
}

contract AllocationMorpho {
    function position(Id, address) external pure returns (uint256, uint128, uint128) {
        return (0, 0, 0);
    }

    function market(Id) external pure returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    function supply(MarketParams memory, uint256, uint256, address, bytes memory)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }
}

contract BlueMidnightAdapterAllocationTest is Test {
    BlueMidnightAdapter adapter;
    AllocationVault vault;
    AllocationToken token;
    AllocationMorpho morpho;
    MarketParams market = MarketParams(address(0), address(1), address(2), address(3), 0);

    function setUp() public {
        token = new AllocationToken();
        vault = new AllocationVault(address(token));
        morpho = new AllocationMorpho();
        adapter = new BlueMidnightAdapter(address(vault), address(4), address(morpho), address(5));
        market.loanToken = address(token);
    }

    function _configure() internal {
        bytes memory data = abi.encodeWithSelector(adapter.setBlueMarket.selector, market);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setBlueMarket(market);
    }

    function testConstructorStartsNonzeroEpochAndBindsAsset() public view {
        assertEq(adapter.asset(), address(token));
        assertEq(adapter.policyEpoch(), 1);
        assertEq(adapter.parentVault(), address(vault));
    }

    function testOnlyParentVaultCanAllocate() public {
        _configure();
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.allocate(abi.encode(market), 1, bytes4(0), address(0));
    }

    function testAllocationRejectsUnconfiguredMarket() public {
        vm.expectRevert(BlueMidnightAdapter.InvalidMarket.selector);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 1, bytes4(0), address(0));
    }
}
