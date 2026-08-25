// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";

contract TimelockToken {
    function approve(address, uint256) external pure returns (bool) { return true; }
}

contract TimelockVault {
    address public immutable token;
    address public curator;
    mapping(address => bool) public sentinels;
    constructor(address _token) { token = _token; curator = msg.sender; }
    function asset() external view returns (address) { return token; }
    function isSentinel(address account) external view returns (bool) { return sentinels[account]; }
    function setSentinel(address account, bool enabled) external { sentinels[account] = enabled; }
}

contract BlueMidnightAdapterTimelockTest is Test {
    BlueMidnightAdapter adapter;
    TimelockVault vault;
    TimelockToken token;

    function setUp() public {
        token = new TimelockToken();
        vault = new TimelockVault(address(token));
        adapter = new BlueMidnightAdapter(address(vault), address(4), address(5), address(6), Market({
            chainId: block.chainid, midnight: address(4), loanToken: address(token),
            collateralParams: new CollateralParams[](0), maturity: block.timestamp + 30 days,
            rcfThreshold: 0, enterGate: address(0), liquidatorGate: address(0)
        }));
    }

    function testCuratorCanSubmitAndExecuteQuoterTimelock() public {
        bytes memory data = abi.encodeWithSelector(adapter.setQuoter.selector, address(this), true);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setQuoter(address(this), true);
        assertTrue(adapter.isQuoter(address(this)));
    }

    function testSentinelCanRevokePendingExpansion() public {
        bytes memory data = abi.encodeWithSelector(adapter.setQuoter.selector, address(this), true);
        adapter.submit(data);
        vault.setSentinel(address(this), true);
        adapter.revoke(data);
        assertEq(adapter.executableAt(data), 0);
    }

    function testUnauthorizedCannotSubmit() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.submit(abi.encodeWithSelector(adapter.setQuoter.selector, address(this), true));
    }

    function testDecreaseTimelockUsesTargetSelectorDelay() public {
        bytes memory data = abi.encodeWithSelector(adapter.decreaseTimelock.selector, adapter.setQuoter.selector, 0);
        adapter.submit(data);
        assertEq(adapter.executableAt(data), block.timestamp + 2 days);
        vm.warp(adapter.executableAt(data));
        adapter.decreaseTimelock(adapter.setQuoter.selector, 0);
        assertEq(adapter.timelock(adapter.setQuoter.selector), 0);
    }
}
