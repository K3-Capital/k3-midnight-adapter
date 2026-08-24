// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";

contract ExitToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ExitVault {
    address public immutable token;
    address public immutable curator;
    mapping(address => bool) public sentinels;

    constructor(address token_) {
        token = token_;
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

contract ExitMorpho {
    using MarketParamsLib for MarketParams;
    ExitToken immutable token;
    mapping(bytes32 => uint256) public shares;

    constructor(address token_) {
        token = ExitToken(token_);
    }

    function position(Id id, address) external view returns (uint256, uint128, uint128) {
        return (shares[Id.unwrap(id)], 0, 0);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (999_999, 0, 0, 0, 0, 0);
    }

    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        token.transferFrom(msg.sender, address(this), assets);
        shares[id] += assets;
        return (assets, assets);
    }

    function withdraw(MarketParams calldata params, uint256 assets, uint256, address, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        require(shares[id] >= assets, "illiquid");
        shares[id] -= assets;
        token.transfer(receiver, assets);
        return (assets, assets);
    }
}

contract BlueMidnightAdapterExitTest is Test {
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;
    BlueMidnightAdapter adapter;
    MarketParams market;
    address sentinel = address(0xBEEF);

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

    function testRiskOffPreservesSynchronousRecovery() public {
        token.mint(address(vault), 100);
        vm.prank(address(vault));
        token.transfer(address(adapter), 100);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 100, bytes4(0), address(0));
        assertEq(adapter.expectedSupplyAssets(), 100);

        vault.setSentinel(sentinel, true);
        vm.prank(sentinel);
        adapter.riskOff(bytes32("incident"));

        vm.prank(address(vault));
        adapter.deallocate(abi.encode(market), 100, bytes4(0), address(0));
        assertEq(token.balanceOf(address(adapter)), 100);
        assertTrue(adapter.riskOffActive());
    }

    function testIlliquidDeallocationRevertsWithoutAccountingDrift() public {
        token.mint(address(vault), 100);
        vm.prank(address(vault));
        token.transfer(address(adapter), 100);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 100, bytes4(0), address(0));
        uint256 beforeSupply = adapter.expectedSupplyAssets();

        vm.expectRevert();
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(market), 101, bytes4(0), address(0));
        assertEq(adapter.expectedSupplyAssets(), beforeSupply);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testSafeExitPayloadIsVersionGated() public {
        bytes memory malformed = abi.encode(uint8(2), new bytes[](0), uint256(0));
        vm.expectRevert(BlueMidnightAdapter.InvalidExitPayload.selector);
        vm.prank(address(vault));
        adapter.deallocate(malformed, 1, bytes4(0), address(0));
    }
}
