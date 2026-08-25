// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";

contract AllocationToken {
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

contract AllocationVault {
    address public immutable token;
    address public curator;
    mapping(bytes32 => uint256) public allocations;

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

    function allocation(bytes32 id) external view returns (uint256) {
        return allocations[id];
    }

    function setAllocation(bytes32 id, uint256 amount) external {
        allocations[id] = amount;
    }
}

contract AllocationMorpho {
    using MarketParamsLib for MarketParams;
    AllocationToken public immutable token;
    mapping(bytes32 => uint256) public shares;
    mapping(bytes32 => uint128[6]) internal markets;

    constructor(address _token) {
        token = AllocationToken(_token);
    }

    function position(Id id, address) external view returns (uint256, uint128, uint128) {
        return (shares[Id.unwrap(id)], 0, 0);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        uint128[6] memory m = markets[Id.unwrap(id)];
        return (m[0], m[1], m[2], m[3], m[4], m[5]);
    }

    function supply(MarketParams memory params, uint256 assets, uint256, address, bytes memory)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        token.transferFrom(msg.sender, address(this), assets);
        shares[id] += assets;
        markets[id][0] += uint128(assets);
        markets[id][1] += uint128(assets);
        return (assets, assets);
    }

    function withdraw(MarketParams memory params, uint256 assets, uint256, address, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        require(shares[id] >= assets, "shares");
        shares[id] -= assets;
        markets[id][0] -= uint128(assets);
        markets[id][1] -= uint128(assets);
        token.transfer(receiver, assets);
        return (assets, assets);
    }

    function setMarket(Id id, uint128 supplyAssets, uint128 supplyShares, uint128 borrowAssets) external {
        markets[Id.unwrap(id)][0] = supplyAssets;
        markets[Id.unwrap(id)][1] = supplyShares;
        markets[Id.unwrap(id)][2] = borrowAssets;
    }

    function setShares(Id id, uint256 amount) external {
        shares[Id.unwrap(id)] = amount;
    }
}

contract BlueMidnightAdapterAllocationTest is Test {
    using MarketParamsLib for MarketParams;
    BlueMidnightAdapter adapter;
    AllocationVault vault;
    AllocationToken token;
    AllocationMorpho morpho;
    MarketParams market = MarketParams(address(0), address(1), address(2), address(3), 0);

    function setUp() public {
        token = new AllocationToken();
        vault = new AllocationVault(address(token));
        morpho = new AllocationMorpho(address(token));
        market.loanToken = address(token);
        MarketEconomicPolicy memory policy = MarketEconomicPolicy(1_000, 0, 30 days, 20 days, 0, 0, true);
        adapter = new BlueMidnightAdapter(
            address(vault), market, address(4), address(morpho), address(5), _pinnedMarket(), policy, address(this)
        );
    }

    function _pinnedMarket() internal view returns (Market memory) {
        return Market({
            chainId: block.chainid,
            midnight: address(4),
            loanToken: address(token),
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _configure() internal {
        // Configuration is pinned in the constructor.
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
        MarketParams memory invalid = market;
        invalid.oracle = address(9);
        vm.expectRevert(BlueMidnightAdapter.InvalidMarket.selector);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(invalid), 1, bytes4(0), address(0));
    }

    function testAllocationAndDeallocationReturnAssetsThroughAdapter() public {
        _configure();
        token.mint(address(vault), 100);
        vm.prank(address(vault));
        token.transfer(address(adapter), 100);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 100, bytes4(0), address(0));
        assertEq(token.balanceOf(address(morpho)), 100);

        vm.prank(address(vault));
        adapter.deallocate(abi.encode(market), 100, bytes4(0), address(0));
        assertEq(token.balanceOf(address(adapter)), 100);
        vm.prank(address(vault));
        token.transferFrom(address(adapter), address(vault), 100);
        assertEq(token.balanceOf(address(vault)), 100);
    }

    function testBuyerBoundUsesBorrowLiquidity() public {
        _configure();
        token.mint(address(vault), 1_000_000);
        vm.prank(address(vault));
        token.transfer(address(adapter), 1_000_000);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 1_000_000, bytes4(0), address(0));
        morpho.setMarket(market.id(), 1_000_000, 1_000_000, 900_000);

        assertEq(adapter.blueAvailableLiquidity(), 100_000);
        assertEq(adapter.expectedSupplyAssets(), 500_000);
        assertFalse(adapter.riskOffActive());
        assertEq(adapter.blueAvailableLiquidity(), 100_000);
    }

    function testBuyerBoundUsesOnlyVaultAllocationAndBlueLiquidity() public {
        _configure();
        token.mint(address(vault), 1_000);
        vm.prank(address(vault));
        token.transfer(address(adapter), 1_000);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), 1_000, bytes4(0), address(0));
        morpho.setShares(market.id(), 4_000_000);
        morpho.setMarket(market.id(), 1_000, 4_000_000, 200);
        vault.setAllocation(adapter.adapterId(), 700);

        assertEq(adapter.buyerAssetsBound(adapter.pinnedMidnightMarketHash()), 700);

        morpho.setMarket(market.id(), 1_000, 2_000_000, 800);
        assertEq(adapter.buyerAssetsBound(adapter.pinnedMidnightMarketHash()), 200);
    }
}
