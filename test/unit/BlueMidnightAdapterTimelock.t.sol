// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";

contract TimelockToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract TimelockVault {
    address public immutable token;
    address public curator;
    mapping(address => bool) public sentinels;

    constructor(address _token) {
        token = _token;
        curator = msg.sender;
    }

    function asset() external view returns (address) {
        return token;
    }

    function isSentinel(address account) external view returns (bool) {
        return sentinels[account];
    }

    function setSentinel(address account, bool enabled) external {
        sentinels[account] = enabled;
    }
}

contract BlueMidnightAdapterTimelockTest is Test {
    BlueMidnightAdapter adapter;
    TimelockVault vault;
    TimelockToken token;
    bytes4 constant SELECTOR = bytes4(keccak256("setExposureCaps(uint256,uint256)"));

    function setUp() public {
        token = new TimelockToken();
        vault = new TimelockVault(address(token));
        adapter = new BlueMidnightAdapter(address(vault), address(4), address(5), address(6));
    }

    function testCuratorCanSubmitAndExecuteSelectorSpecificTimelock() public {
        bytes memory data = abi.encodeWithSelector(SELECTOR, 100, 50);
        adapter.submit(data);
        assertGe(adapter.executableAt(data), block.timestamp);
        vm.warp(adapter.executableAt(data));
        adapter.setExposureCaps(100, 50);
        assertEq(adapter.globalExposureCap(), 100);
        assertEq(adapter.targetExposureCap(), 50);
    }

    function testSentinelCanRevokePendingExpansion() public {
        bytes memory data = abi.encodeWithSelector(SELECTOR, 100, 50);
        adapter.submit(data);
        vault.setSentinel(address(this), true);
        adapter.revoke(data);
        assertEq(adapter.executableAt(data), 0);
    }

    function testUnauthorizedCannotSubmit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.submit(abi.encodeWithSelector(SELECTOR, 100, 50));
    }
}
