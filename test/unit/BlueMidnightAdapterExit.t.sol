// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IBuyCallback, ISellCallback} from "midnight/interfaces/ICallbacks.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {MarketEconomicPolicy, SafeExit} from "../../src/types/AdapterTypes.sol";

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

    function market(Id) external pure returns (uint128, uint128, uint128, uint128, uint128, uint128) {
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

contract ExitMidnight {
    using HashLib for Market;
    ExitToken immutable token;
    mapping(bytes32 => uint256) public credits;
    mapping(bytes32 => uint256) public available;
    mapping(bytes32 => uint256) public saleAssets;
    mapping(bytes32 => uint256) public pendingFees;

    constructor(address token_) {
        token = ExitToken(token_);
    }

    function seed(Market calldata market, uint256 credit, uint256 availableAssets, uint256 sellerAssets) external {
        bytes32 id = market.hashMarket();
        credits[id] = credit;
        available[id] = availableAssets;
        saleAssets[id] = sellerAssets;
    }

    function invokeBuy(address adapter, Market calldata market, uint256 buyerAssets, uint256 units) external {
        invokeBuyWithFee(adapter, market, buyerAssets, units, 0);
    }

    function invokeBuyWithFee(address adapter, Market calldata market, uint256 buyerAssets, uint256 units, uint256 fee)
        public
    {
        bytes32 id = market.hashMarket();
        IBuyCallback(adapter).onBuy(id, market, buyerAssets, units, fee, adapter, hex"");
        token.transferFrom(adapter, address(this), buyerAssets);
        credits[id] = units;
        pendingFees[id] = fee;
    }

    function withdrawable(bytes32 id) external view returns (uint256) {
        return available[id];
    }

    function updatePositionView(Market calldata market, bytes32 id, address)
        external
        view
        returns (uint128, uint128, uint128)
    {
        market;
        return (uint128(credits[id]), uint128(pendingFees[id]), 0);
    }

    function withdraw(Market calldata market, uint256 units, address, address receiver) external {
        bytes32 id = market.hashMarket();
        available[id] -= units;
        credits[id] -= units;
        token.transfer(receiver, units);
    }

    function take(
        Offer calldata offer,
        bytes calldata,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes calldata takerCallbackData
    ) external returns (uint256, uint256) {
        bytes32 id = offer.market.hashMarket();
        uint256 sellerAssets = saleAssets[id];
        credits[id] -= units;
        token.transfer(receiverIfTakerIsSeller, sellerAssets);
        ISellCallback(takerCallback)
            .onSell(id, offer.market, sellerAssets, units, 0, taker, receiverIfTakerIsSeller, takerCallbackData);
        return (0, sellerAssets);
    }
}

contract BlueMidnightAdapterExitTest is Test {
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;
    ExitMidnight midnight;
    BlueMidnightAdapter adapter;
    MarketParams market;
    Market midnightMarket;
    bytes32 midnightMarketId;
    address sentinel = address(0xBEEF);

    function setUp() public {
        token = new ExitToken();
        vault = new ExitVault(address(token));
        morpho = new ExitMorpho(address(token));
        midnight = new ExitMidnight(address(token));
        adapter = new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(5));
        market = MarketParams(address(token), address(1), address(2), address(3), 0);
        bytes memory data = abi.encodeWithSelector(adapter.setBlueMarket.selector, market);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setBlueMarket(market);
        midnightMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(token),
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        midnightMarketId = HashLib.hashMarket(midnightMarket);
        MarketEconomicPolicy memory policy = MarketEconomicPolicy(1_000, 0, 30 days, 20 days, 0, 0, true);
        data = abi.encodeWithSelector(adapter.setMarketEconomicPolicy.selector, midnightMarketId, policy);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setMarketEconomicPolicy(midnightMarketId, policy);
        data = abi.encodeWithSelector(adapter.setMarketPolicy.selector, midnightMarketId, 1_000_000, 1_000_000, true);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setMarketPolicy(midnightMarketId, 1_000_000, 1_000_000, true);
        data = abi.encodeWithSelector(adapter.setExposureCaps.selector, 1_000_000, 1_000_000);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setExposureCaps(1_000_000, 1_000_000);
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

    function testExitLossLimitExpansionIsTimelocked() public {
        bytes memory data = abi.encodeWithSelector(adapter.setExitLossLimit.selector, 10);
        adapter.submit(data);
        assertGt(adapter.executableAt(data), block.timestamp);
        vm.expectRevert(BlueMidnightAdapter.TimelockNotExpired.selector);
        adapter.setExitLossLimit(10);
    }

    function testEarlyRepaymentIsCollectedAndResuppliedAfterRiskOff() public {
        _seedCredit(100);
        token.mint(address(midnight), 25);
        midnight.seed(midnightMarket, 100, 25, 0);

        vault.setSentinel(sentinel, true);
        vm.prank(sentinel);
        adapter.riskOff(bytes32("repayment"));

        uint256 collected = adapter.collectRepayments(_markets(midnightMarket), _units(25));
        assertEq(collected, 25);
        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 75);
        bytes32 blueId;
        (, blueId) = adapter.blueMarket();
        assertEq(morpho.shares(blueId), 25);
    }

    function testSafeExitSucceedsAfterMarketDisableAndReportsRealizedLoss() public {
        _seedCredit(100);
        _setExitLossLimit(20);
        token.mint(address(midnight), 80);
        midnight.seed(midnightMarket, 100, 0, 80);
        vault.setSentinel(sentinel, true);
        vm.prank(sentinel);
        adapter.disableMarket(midnightMarketId);

        SafeExit[] memory exits = new SafeExit[](1);
        exits[0] = SafeExit(_offer(), hex"", 100);
        bytes memory data = abi.encode(uint8(1), exits, uint256(20));
        vm.prank(address(vault));
        adapter.deallocate(data, 80, bytes4(0), address(0));

        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 0);
        assertEq(token.balanceOf(address(adapter)), 80);
    }

    function testSafeExitRejectsCheapSaleAgainstRemovedBookValue() public {
        _seedCredit(100);
        _setExitLossLimit(10);
        token.mint(address(midnight), 80);
        midnight.seed(midnightMarket, 100, 0, 80);

        SafeExit[] memory exits = new SafeExit[](1);
        exits[0] = SafeExit(_offer(), hex"", 100);
        bytes memory data = abi.encode(uint8(1), exits, uint256(10));
        vm.expectRevert(BlueMidnightAdapter.ExitLossExceeded.selector);
        vm.prank(address(vault));
        adapter.deallocate(data, 80, bytes4(0), address(0));

        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 100);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testSafeExitAllowsZeroLossPartialSaleWithExistingBlueLiquidity() public {
        _seedCredit(100);
        _allocateBlueLiquidity(70);
        token.mint(address(midnight), 30);
        midnight.seed(midnightMarket, 100, 0, 30);

        SafeExit[] memory exits = new SafeExit[](1);
        exits[0] = SafeExit(_offer(), hex"", 30);
        bytes memory data = abi.encode(uint8(1), exits, uint256(0));
        vm.prank(address(vault));
        adapter.deallocate(data, 100, bytes4(0), address(0));

        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 70);
        assertEq(token.balanceOf(address(adapter)), 100);
    }

    function testSafeExitLossUsesAccruedPostCheckpointBookValue() public {
        _seedCredit(100);
        midnight.invokeBuyWithFee(address(adapter), midnightMarket, 0, 0, 50);
        vm.warp(block.timestamp + 15 days);
        token.mint(address(midnight), 30);
        midnight.seed(midnightMarket, 70, 0, 30);

        SafeExit[] memory exits = new SafeExit[](1);
        exits[0] = SafeExit(_offer(), hex"", 30);
        bytes memory data = abi.encode(uint8(1), exits, uint256(0));
        vm.expectRevert(BlueMidnightAdapter.ExitLossExceeded.selector);
        vm.prank(address(vault));
        adapter.deallocate(data, 30, bytes4(0), address(0));

        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 100);
    }

    function _seedCredit(uint256 assets) internal {
        token.mint(address(vault), assets);
        vm.prank(address(vault));
        token.transfer(address(adapter), assets);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), assets, bytes4(0), address(0));
        midnight.invokeBuy(address(adapter), midnightMarket, assets, assets);
    }

    function _allocateBlueLiquidity(uint256 assets) internal {
        token.mint(address(vault), assets);
        vm.prank(address(vault));
        token.transfer(address(adapter), assets);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(market), assets, bytes4(0), address(0));
    }

    function _setExitLossLimit(uint256 limit) internal {
        bytes memory data = abi.encodeWithSelector(adapter.setExitLossLimit.selector, limit);
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        adapter.setExitLossLimit(limit);
    }

    function _offer() internal view returns (Offer memory) {
        return Offer({
            market: midnightMarket,
            buy: true,
            maker: address(0xCAFE),
            start: block.timestamp,
            expiry: block.timestamp + 1 days,
            tick: 1,
            group: bytes32(0),
            callback: address(0),
            callbackData: hex"",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(5),
            reduceOnly: false,
            maxUnits: 0,
            maxAssets: 100,
            continuousFeeCap: 0
        });
    }

    function _markets(Market memory value) internal pure returns (Market[] memory values) {
        values = new Market[](1);
        values[0] = value;
    }

    function _units(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }
}
