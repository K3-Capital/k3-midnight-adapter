// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {PolicySetterRatifier} from "../../src/PolicySetterRatifier.sol";
import {IPolicySetterRatifier} from "../../src/interfaces/IPolicySetterRatifier.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Market, Offer, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {MarketAccounting} from "../../src/types/AdapterTypes.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {CALLBACK_SUCCESS, MAX_CONTINUOUS_FEE, MAX_SETTLEMENT_FEE_360_DAYS} from "midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "midnight/libraries/TickLib.sol";

contract AccountingTokenMock {
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
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AccountingVaultMock {
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

contract AccountingMorphoMock {
    using MarketParamsLib for MarketParams;
    AccountingTokenMock immutable token;
    mapping(bytes32 => uint256) public shares;
    mapping(bytes32 => uint128[3]) public balances;

    constructor(address token_) {
        token = AccountingTokenMock(token_);
    }

    function position(Id id, address) external view returns (uint256, uint128, uint128) {
        return (shares[Id.unwrap(id)], 0, 0);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        uint128[3] memory b = balances[Id.unwrap(id)];
        return (b[0], b[1], b[2], 0, 0, 0);
    }

    function supply(MarketParams calldata params, uint256 assets, uint256, address, bytes calldata)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        token.transferFrom(msg.sender, address(this), assets);
        shares[id] += assets;
        balances[id][0] += uint128(assets);
        balances[id][1] += uint128(assets);
        return (assets, assets);
    }

    function withdraw(MarketParams calldata params, uint256 assets, uint256, address, address receiver)
        external
        returns (uint256, uint256)
    {
        bytes32 id = Id.unwrap(params.id());
        shares[id] -= assets;
        balances[id][0] -= uint128(assets);
        balances[id][1] -= uint128(assets);
        token.transfer(receiver, assets);
        return (assets, assets);
    }

    function setBalances(Id id, uint128 supplyAssets, uint128 supplyShares, uint128 borrowAssets, uint256 shareBalance)
        external
    {
        balances[Id.unwrap(id)] = [supplyAssets, supplyShares, borrowAssets];
        shares[Id.unwrap(id)] = shareBalance;
    }
}

contract AccountingMidnightMock {
    uint32 public continuous;
    uint64 public settlement;
    AccountingTokenMock immutable token;
    PolicySetterRatifier public ratifier;
    mapping(bytes32 => uint128) public credit;
    mapping(bytes32 => uint128) public pendingFee;

    constructor(address token_) {
        token = AccountingTokenMock(token_);
    }

    function setRatifier(PolicySetterRatifier ratifier_) external {
        ratifier = ratifier_;
    }

    function setFees(uint32 continuous_, uint64 settlement_) external {
        continuous = continuous_;
        settlement = settlement_;
    }

    function continuousFee(bytes32) external view returns (uint32) {
        return continuous;
    }

    function settlementFee(bytes32, uint256) external view returns (uint64) {
        return settlement;
    }

    function invokeBuy(
        BlueMidnightAdapter adapter,
        bytes32 id,
        Market calldata market,
        uint256 assets,
        uint256 units,
        uint256 fee,
        address buyer,
        bytes calldata data
    ) external returns (bytes32) {
        return adapter.onBuy(IdLib.toId(market), market, assets, units, fee, buyer, data);
    }

    function takeMakerBuy(
        BlueMidnightAdapter adapter,
        Offer calldata offer,
        bytes calldata ratifierData,
        uint256 assets,
        uint256 units,
        uint256 fee
    ) external returns (bytes32) {
        ratifier.isRatified(offer, ratifierData, address(0));
        require(assets <= offer.maxAssets, "offer asset limit");
        bytes32 id = HashLib.hashMarket(offer.market);
        bytes32 protocolId = IdLib.toId(offer.market);
        bytes32 result = adapter.onBuy(protocolId, offer.market, assets, units, fee, address(adapter), "");
        token.transferFrom(address(adapter), address(this), assets);
        credit[id] += uint128(units);
        pendingFee[id] += uint128(fee);
        credit[protocolId] += uint128(units);
        pendingFee[protocolId] += uint128(fee);
        return result;
    }

    function takeMakerBuy(
        BlueMidnightAdapter adapter,
        bytes32 id,
        Market calldata market,
        uint256 assets,
        uint256 units,
        uint256 fee
    ) external returns (bytes32) {
        bytes32 protocolId = IdLib.toId(market);
        bytes32 result = adapter.onBuy(protocolId, market, assets, units, fee, address(adapter), "");
        token.transferFrom(address(adapter), address(this), assets);
        credit[id] += uint128(units);
        pendingFee[id] += uint128(fee);
        credit[protocolId] += uint128(units);
        pendingFee[protocolId] += uint128(fee);
        return result;
    }

    function takeMakerSell(
        BlueMidnightAdapter adapter,
        bytes32 id,
        Market calldata market,
        uint256 assets,
        uint256 units,
        uint256 feeDecrease
    ) external returns (bytes32) {
        credit[id] -= uint128(units);
        pendingFee[id] -= uint128(feeDecrease);
        bytes32 protocolId = IdLib.toId(market);
        credit[protocolId] -= uint128(units);
        pendingFee[protocolId] -= uint128(feeDecrease);
        uint256 balance = token.balanceOf(address(this));
        if (assets > balance) token.mint(address(this), assets - balance);
        token.transfer(address(adapter), assets);
        return
            adapter.onSell(
                IdLib.toId(market), market, assets, units, feeDecrease, address(adapter), address(adapter), ""
            );
    }

    function setPosition(bytes32 id, uint128 credit_, uint128 pendingFee_) external {
        credit[id] = credit_;
        pendingFee[id] = pendingFee_;
    }

    function updatePositionView(Market calldata, bytes32 id, address)
        external
        view
        returns (uint128, uint128, uint128)
    {
        return (credit[id], pendingFee[id], 0);
    }
}

contract BlueMidnightAdapterAccountingTest is Test {
    using MarketParamsLib for MarketParams;
    AccountingTokenMock token;
    AccountingVaultMock vault;
    AccountingMorphoMock morpho;
    AccountingMidnightMock midnight;
    BlueMidnightAdapter adapter;
    PolicySetterRatifier ratifier;
    MarketParams blueMarket;
    Market midnightMarket;
    bytes32 midnightId;

    event SellFill(bytes32 indexed marketId, uint256 assets, uint256 units, int256 pnl);

    function setUp() public {
        token = new AccountingTokenMock();
        vault = new AccountingVaultMock(address(token));
        morpho = new AccountingMorphoMock(address(token));
        midnight = new AccountingMidnightMock(address(token));
        ratifier = new PolicySetterRatifier(address(midnight));
        adapter = new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(ratifier));
        midnight.setRatifier(ratifier);
        blueMarket = MarketParams(address(token), address(1), address(2), address(3), 0);
        bytes memory blueData = abi.encodeWithSelector(adapter.setBlueMarket.selector, blueMarket);
        adapter.submit(blueData);
        vm.warp(adapter.executableAt(blueData));
        adapter.setBlueMarket(blueMarket);
        midnightMarket = Market(
            block.chainid,
            address(midnight),
            address(token),
            new CollateralParams[](0),
            block.timestamp + 31 days,
            0,
            address(0),
            address(0)
        );
        midnightId = HashLib.hashMarket(midnightMarket);
        MarketEconomicPolicy memory economicPolicy = MarketEconomicPolicy({
            maxBuyTick: 100,
            minSellTick: 10,
            maxTenor: 31 days,
            maxExpiryHorizon: 30 days,
            maxContinuousFeePerSecondWad: 0,
            maxSettlementFeeWad: 0,
            configured: true
        });
        bytes memory economicPolicyData =
            abi.encodeWithSelector(adapter.setMarketEconomicPolicy.selector, midnightId, economicPolicy);
        adapter.submit(economicPolicyData);
        vm.warp(adapter.executableAt(economicPolicyData));
        adapter.setMarketEconomicPolicy(midnightId, economicPolicy);
        bytes memory policyData =
            abi.encodeWithSelector(adapter.setMarketPolicy.selector, midnightId, 1_000_000, 1_000_000, true);
        adapter.submit(policyData);
        vm.warp(adapter.executableAt(policyData));
        adapter.setMarketPolicy(midnightId, 1_000_000, 1_000_000, true);
        bytes memory capsData = abi.encodeWithSelector(adapter.setExposureCaps.selector, 1_000_000, 1_000_000);
        adapter.submit(capsData);
        vm.warp(adapter.executableAt(capsData));
        adapter.setExposureCaps(1_000_000, 1_000_000);
        bytes memory quoterData = abi.encodeWithSelector(adapter.setQuoter.selector, address(this), true);
        adapter.submit(quoterData);
        vm.warp(adapter.executableAt(quoterData));
        adapter.setQuoter(address(this), true);
        token.mint(address(morpho), 1_000_000);
        morpho.setBalances(blueMarket.id(), 1_000_000, 1_000_000_000_000, 0, 1_000_000_000_000);
    }

    function testBuyUsesConfiguredBlueMarketAndPreservesNav() public {
        bytes32 result = midnight.invokeBuy(adapter, midnightId, midnightMarket, 100, 100, 0, address(adapter), "");
        assertEq(result, CALLBACK_SUCCESS);
        MarketAccounting memory a = adapter.marketAccounting(midnightId);
        assertEq(a.bookValue, 100);
        assertEq(a.trackedCredit, 100);
        // The view uses the current Midnight position as an upper bound, so a callback cannot double count the
        // withdrawn Blue assets as both Blue supply and Midnight credit.
        assertLe(adapter.realAssets(), 1_000_000);
    }

    function testStatefulBuyPullsAssetsAndSellResuppliesBlueWithoutNavDoubleCount() public {
        uint256 initialNav = adapter.realAssets();

        bytes32 buyResult = midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 0);
        assertEq(buyResult, CALLBACK_SUCCESS);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(midnight)), 100);
        assertEq(adapter.realAssets(), initialNav);

        bytes32 sellResult = midnight.takeMakerSell(adapter, midnightId, midnightMarket, 110, 100, 0);
        assertEq(sellResult, CALLBACK_SUCCESS);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(midnight)), 0);
        // Morpho's virtual-share conversion rounds the mock's one-decimal gain down by one unit;
        // the assertion still proves proceeds appear once in Blue rather than as duplicated adapter cash.
        assertEq(adapter.realAssets(), initialNav + 9);
    }

    function testStatefulBuyAccruesClaimFromFillTimeOnlyUntilMaturity() public {
        uint256 fillTime = midnightMarket.maturity - 31 days;
        vm.warp(fillTime);
        uint256 initialNav = adapter.realAssets();

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        MarketAccounting memory filled = adapter.marketAccounting(midnightId);
        assertEq(filled.bookValue, 100);
        assertEq(filled.netMaturityClaim, 120);
        _assertAccounting(midnightId, 100, 120, 100, uint40(fillTime), true);
        assertEq(adapter.realAssets(), initialNav);

        vm.warp(fillTime + 10 days);
        assertEq(adapter.realAssets(), initialNav + 6);
        _assertAccounting(midnightId, 100, 120, 100, uint40(fillTime), true);

        vm.warp(midnightMarket.maturity);
        assertEq(adapter.realAssets(), initialNav + 20);
        _assertAccounting(midnightId, 100, 120, 100, uint40(fillTime), true);

        vm.warp(midnightMarket.maturity + 1 days);
        assertEq(adapter.realAssets(), initialNav + 20);
        _assertAccounting(midnightId, 100, 120, 100, uint40(fillTime), true);
    }

    function testDistinctTimeFillsCheckpointExistingAccrualBeforeAddingNewClaim() public {
        uint256 fillTime = midnightMarket.maturity - 31 days;
        vm.warp(fillTime);
        uint256 initialNav = adapter.realAssets();

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        vm.warp(fillTime + 10 days);
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 50, 50, 10);

        MarketAccounting memory secondFill = adapter.marketAccounting(midnightId);
        assertEq(secondFill.bookValue, 156);
        assertEq(secondFill.netMaturityClaim, 180);
        _assertAccounting(midnightId, 156, 180, 150, uint40(fillTime + 10 days), true);
        assertEq(adapter.realAssets(), initialNav + 6);
        _assertAccounting(midnightId, 156, 180, 150, uint40(fillTime + 10 days), true);

        vm.warp(fillTime + 20 days);
        assertEq(adapter.realAssets(), initialNav + 17);
        _assertAccounting(midnightId, 156, 180, 150, uint40(fillTime + 10 days), true);

        vm.warp(midnightMarket.maturity);
        assertEq(adapter.realAssets(), initialNav + 30);
        _assertAccounting(midnightId, 156, 180, 150, uint40(fillTime + 10 days), true);

        vm.warp(midnightMarket.maturity + 1 days);
        assertEq(adapter.realAssets(), initialNav + 30);
        _assertAccounting(midnightId, 156, 180, 150, uint40(fillTime + 10 days), true);
    }

    function testLossSaleAndNewBuyPreserveLossAndEmitNegativeRealizedPnl() public {
        uint256 fillTime = midnightMarket.maturity - 31 days;
        vm.warp(fillTime);
        uint256 initialNav = adapter.realAssets();
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 101, 100, 23);
        _assertAccounting(midnightId, 101, 124, 100, uint40(fillTime), true);
        _assertBluePosition(999_899, 999_999_999_899);
        assertEq(adapter.realAssets(), initialNav);
        assertEq(token.balanceOf(address(adapter)), 0);

        // Midnight's independently synchronized position has lost 34 units of credit and claim before the sale.
        midnight.setPosition(IdLib.toId(midnightMarket), 83, 7);
        _assertAccounting(midnightId, 101, 124, 100, uint40(fillTime), true);
        _assertBluePosition(999_899, 999_999_999_899);
        assertEq(adapter.realAssets(), initialNav - 11);
        assertEq(token.balanceOf(address(adapter)), 0);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit SellFill(midnightId, 30, 37, -7);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 30, 37, 0);

        MarketAccounting memory afterSale = adapter.marketAccounting(midnightId);
        assertEq(afterSale.bookValue, 46);
        assertEq(afterSale.netMaturityClaim, 53);
        assertEq(afterSale.trackedCredit, 46);
        _assertAccounting(midnightId, 46, 53, 46, uint40(fillTime), true);
        _assertBluePosition(999_929, 999_999_999_929);
        assertEq(adapter.realAssets(), initialNav - 25);
        assertEq(token.balanceOf(address(adapter)), 0);

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 19, 19, 6);
        MarketAccounting memory afterNewBuy = adapter.marketAccounting(midnightId);
        assertEq(afterNewBuy.bookValue, 65);
        assertEq(afterNewBuy.netMaturityClaim, 78);
        assertEq(afterNewBuy.trackedCredit, 65);
        _assertAccounting(midnightId, 65, 78, 65, uint40(fillTime), true);
        _assertBluePosition(999_910, 999_999_999_910);
        assertEq(adapter.realAssets(), initialNav - 25);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testTwoIndependentlyRatifiedOffersExecuteStatefulBuys() public {
        Offer memory first = _validBuyOffer(100);
        Offer memory second = _validBuyOffer(150);
        second.expiry += 1;
        bytes32 firstRoot = HashLib.hashOffer(first);
        bytes32 secondRoot = HashLib.hashOffer(second);
        adapter.approveRoot(firstRoot);
        adapter.approveRoot(secondRoot);

        bytes32 firstResult =
            midnight.takeMakerBuy(adapter, first, abi.encode(firstRoot, 0, new bytes32[](0)), 100, 100, 0);
        bytes32 secondResult =
            midnight.takeMakerBuy(adapter, second, abi.encode(secondRoot, 0, new bytes32[](0)), 150, 150, 0);

        assertEq(firstResult, CALLBACK_SUCCESS);
        assertEq(secondResult, CALLBACK_SUCCESS);
        assertEq(token.balanceOf(address(midnight)), 250);
        assertEq(adapter.marketAccounting(midnightId).trackedCredit, 250);
    }

    function testStatefulBuyRejectsUnapprovedAndMismatchedRoots() public {
        Offer memory offer = _validBuyOffer(100);
        bytes32 root = HashLib.hashOffer(offer);
        vm.expectRevert(IPolicySetterRatifier.RootNotApproved.selector);
        midnight.takeMakerBuy(adapter, offer, abi.encode(root, 0, new bytes32[](0)), 100, 100, 0);

        adapter.approveRoot(root);
        bytes32 mismatchedRoot = keccak256("different-root");
        vm.expectRevert(IPolicySetterRatifier.InvalidProof.selector);
        midnight.takeMakerBuy(adapter, offer, abi.encode(mismatchedRoot, 0, new bytes32[](0)), 100, 100, 0);
    }

    function testPartialSellReducesClaimExactlyOnceAfterMidnightUpdatesCredit() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 0);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 50, 50, 0);

        MarketAccounting memory a = adapter.marketAccounting(midnightId);
        assertEq(a.trackedCredit, 50);
        assertEq(a.bookValue, 50);
        assertEq(a.netMaturityClaim, 50);
    }

    function testPartialSellCapsClaimToPostSalePendingFeeAfterRounding() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 3);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 50, 50, 2);

        MarketAccounting memory a = adapter.marketAccounting(midnightId);
        assertEq(a.trackedCredit, 50);
        assertEq(a.bookValue, 50);
        assertEq(a.netMaturityClaim, 51);
    }

    function testActualPartialFillsExhaustMarketAndGlobalExposureCaps() public {
        bytes memory marketData =
            abi.encodeWithSelector(adapter.setMarketPolicy.selector, midnightId, 800_000, 1_000_000, true);
        adapter.submit(marketData);
        vm.warp(adapter.executableAt(marketData));
        adapter.setMarketPolicy(midnightId, 800_000, 1_000_000, true);

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 600_000, 600_000, 0);
        assertEq(adapter.buyerAssetsBound(midnightId), 200_000);

        vm.expectRevert(BlueMidnightAdapter.ExposureExceeded.selector);
        midnight.invokeBuy(adapter, midnightId, midnightMarket, 200_001, 200_001, 0, address(adapter), "");

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 200_000, 200_000, 0);
        assertEq(adapter.buyerAssetsBound(midnightId), 0);

        Market memory secondMarket = midnightMarket;
        secondMarket.maturity += 1 days;
        bytes32 secondId = HashLib.hashMarket(secondMarket);
        _setEconomicPolicy(adapter, secondId, _policy(100, 10, 32 days, 30 days, 0, 0));
        _enableMarket(adapter, secondId);
        Offer memory secondOffer = _validBuyOffer();
        secondOffer.market = secondMarket;
        secondOffer.expiry = block.timestamp + 1 days;
        secondOffer.group = keccak256(abi.encode(address(adapter), adapter.policyEpoch()));
        assertTrue(adapter.acceptsOffer(secondOffer));
        midnight.takeMakerBuy(adapter, secondId, secondMarket, 200_000, 200_000, 0);
        assertEq(adapter.buyerAssetsBound(secondId), 0);

        vm.expectRevert(BlueMidnightAdapter.ExposureExceeded.selector);
        midnight.invokeBuy(adapter, secondId, secondMarket, 1, 1, 0, address(adapter), "");
    }

    function testOfferBindsEpochGroupAndSellInventory() public {
        Offer memory offer = Offer(
            midnightMarket,
            true,
            address(adapter),
            block.timestamp,
            block.timestamp + 1 days,
            10,
            keccak256(abi.encode(address(adapter), adapter.policyEpoch())),
            address(adapter),
            "",
            address(0),
            adapter.ratifier(),
            false,
            0,
            100,
            0
        );
        assertTrue(adapter.acceptsOffer(offer));
        offer.group = bytes32(0);
        assertFalse(adapter.acceptsOffer(offer));
        offer.buy = false;
        offer.group = keccak256(abi.encode(address(adapter), adapter.policyEpoch()));
        offer.reduceOnly = true;
        offer.receiverIfMakerIsSeller = address(adapter);
        offer.callbackData = "";
        offer.maxUnits = 101;
        offer.maxAssets = 0;
        assertFalse(adapter.acceptsOffer(offer));
    }

    function testEconomicPolicyFixtureEnablesValidOffer() public {
        Offer memory offer = Offer(
            midnightMarket,
            true,
            address(adapter),
            block.timestamp,
            block.timestamp + 1 days,
            10,
            keccak256(abi.encode(address(adapter), adapter.policyEpoch())),
            address(adapter),
            "",
            address(0),
            adapter.ratifier(),
            false,
            0,
            100,
            0
        );

        assertTrue(adapter.acceptsOffer(offer));
    }

    function _assertAccounting(
        bytes32 marketId,
        uint128 expectedBookValue,
        uint128 expectedClaim,
        uint128 expectedCredit,
        uint40 expectedCheckpoint,
        bool expectedActive
    ) internal view {
        MarketAccounting memory a = adapter.marketAccounting(marketId);
        assertEq(a.bookValue, expectedBookValue);
        assertEq(a.netMaturityClaim, expectedClaim);
        assertEq(a.trackedCredit, expectedCredit);
        assertEq(a.lastCheckpoint, expectedCheckpoint);
        assertEq(a.active, expectedActive);
    }

    function _assertBluePosition(uint128 expectedSupplyAssets, uint256 expectedSupplyShares) internal view {
        assertEq(morpho.balances(Id.unwrap(blueMarket.id()), 0), expectedSupplyAssets);
        assertEq(morpho.balances(Id.unwrap(blueMarket.id()), 1), expectedSupplyShares);
        assertEq(morpho.shares(Id.unwrap(blueMarket.id())), expectedSupplyShares);
    }

    function _validBuyOffer() internal view returns (Offer memory) {
        return _validBuyOffer(100);
    }

    function _validBuyOffer(uint128 maxAssets) internal view returns (Offer memory) {
        return Offer(
            midnightMarket,
            true,
            address(adapter),
            block.timestamp,
            block.timestamp + 1 days,
            10,
            keccak256(abi.encode(address(adapter), adapter.policyEpoch())),
            address(adapter),
            "",
            address(0),
            adapter.ratifier(),
            false,
            0,
            maxAssets,
            0
        );
    }

    function testOfferPolicyEnforcesTickHorizonAndFeesAtBoundaries() public {
        Offer memory offer = _validBuyOffer();
        assertTrue(adapter.acceptsOffer(offer));
        offer.tick = 101;
        assertFalse(adapter.acceptsOffer(offer));
        offer.tick = 100;
        assertTrue(adapter.acceptsOffer(offer));
        offer.market.maturity = block.timestamp + 31 days + 1;
        assertFalse(adapter.acceptsOffer(offer));
        offer = _validBuyOffer();
        assertTrue(adapter.acceptsOffer(offer));
        midnight.setFees(1, 0);
        assertFalse(adapter.acceptsOffer(offer));
        midnight.setFees(0, 1);
        assertFalse(adapter.acceptsOffer(offer));
    }

    function testEnableBeforeEconomicPolicyReverts() public {
        bytes32 unconfiguredId = keccak256("unconfigured-market");
        BlueMidnightAdapter fresh =
            new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(0x4444));
        bytes memory data = abi.encodeWithSelector(fresh.setMarketPolicy.selector, unconfiguredId, 1, 1, true);
        fresh.submit(data);
        vm.warp(fresh.executableAt(data));
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        fresh.setMarketPolicy(unconfiguredId, 1, 1, true);
    }

    function testImmediateTighteningBumpsEpochAndRejectsLoosening() public {
        uint64 before = adapter.policyEpoch();
        MarketEconomicPolicy memory tighter = MarketEconomicPolicy({
            maxBuyTick: 99,
            minSellTick: 10,
            maxTenor: 31 days,
            maxExpiryHorizon: 30 days,
            maxContinuousFeePerSecondWad: 0,
            maxSettlementFeeWad: 0,
            configured: true
        });
        adapter.tightenMarketEconomicPolicy(midnightId, tighter);
        assertGt(adapter.policyEpoch(), before);
        MarketEconomicPolicy memory looser = tighter;
        looser.maxBuyTick = 100;
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.tightenMarketEconomicPolicy(midnightId, looser);
    }

    function _policy(
        uint24 maxBuyTick,
        uint24 minSellTick,
        uint40 maxTenor,
        uint40 maxExpiryHorizon,
        uint32 maxFee,
        uint64 maxSettlementFee
    ) internal pure returns (MarketEconomicPolicy memory) {
        return MarketEconomicPolicy({
            maxBuyTick: maxBuyTick,
            minSellTick: minSellTick,
            maxTenor: maxTenor,
            maxExpiryHorizon: maxExpiryHorizon,
            maxContinuousFeePerSecondWad: maxFee,
            maxSettlementFeeWad: maxSettlementFee,
            configured: true
        });
    }

    function _setEconomicPolicy(BlueMidnightAdapter target, bytes32 marketId, MarketEconomicPolicy memory policy)
        internal
    {
        bytes memory data = abi.encodeWithSelector(target.setMarketEconomicPolicy.selector, marketId, policy);
        target.submit(data);
        vm.warp(target.executableAt(data));
        target.setMarketEconomicPolicy(marketId, policy);
    }

    function _enableMarket(BlueMidnightAdapter target, bytes32 marketId) internal {
        bytes memory data =
            abi.encodeWithSelector(target.setMarketPolicy.selector, marketId, 1_000_000, 1_000_000, true);
        target.submit(data);
        vm.warp(target.executableAt(data));
        target.setMarketPolicy(marketId, 1_000_000, 1_000_000, true);
    }

    function _rejectEconomicPolicy(BlueMidnightAdapter target, bytes32 marketId, MarketEconomicPolicy memory policy)
        internal
    {
        uint64 before = target.policyEpoch();
        bytes memory data = abi.encodeWithSelector(target.setMarketEconomicPolicy.selector, marketId, policy);
        target.submit(data);
        vm.warp(target.executableAt(data));
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        target.setMarketEconomicPolicy(marketId, policy);
        assertEq(target.policyEpoch(), before);
        (uint24 maxBuyTick,,,,,, bool configured) = target.marketEconomicPolicy(marketId);
        assertEq(maxBuyTick, 0);
        assertFalse(configured);
    }

    function _assertTighteningRejected(MarketEconomicPolicy memory policy, uint64 expectedEpoch) internal {
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.tightenMarketEconomicPolicy(midnightId, policy);
        assertEq(adapter.policyEpoch(), expectedEpoch);
    }

    function testEconomicPolicyConfigurationRejectsEveryInvalidField() public {
        BlueMidnightAdapter fresh =
            new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(0x4444));
        _rejectEconomicPolicy(fresh, bytes32(0), _policy(100, 10, 31 days, 30 days, 0, 0));
        MarketEconomicPolicy memory unconfigured = _policy(100, 10, 31 days, 30 days, 0, 0);
        unconfigured.configured = false;
        _rejectEconomicPolicy(fresh, keccak256("unconfigured"), unconfigured);
        _rejectEconomicPolicy(fresh, keccak256("buy-tick"), _policy(uint24(MAX_TICK + 1), 10, 31 days, 30 days, 0, 0));
        _rejectEconomicPolicy(fresh, keccak256("sell-tick"), _policy(100, uint24(MAX_TICK + 1), 31 days, 30 days, 0, 0));
        _rejectEconomicPolicy(fresh, keccak256("zero-tenor"), _policy(100, 10, 0, 30 days, 0, 0));
        _rejectEconomicPolicy(fresh, keccak256("zero-expiry"), _policy(100, 10, 31 days, 0, 0, 0));
        _rejectEconomicPolicy(fresh, keccak256("horizon"), _policy(100, 10, 31 days, 31 days + 1, 0, 0));
        _rejectEconomicPolicy(
            fresh, keccak256("continuous-fee"), _policy(100, 10, 31 days, 30 days, uint32(MAX_CONTINUOUS_FEE + 1), 0)
        );
        _rejectEconomicPolicy(
            fresh,
            keccak256("settlement-fee"),
            _policy(100, 10, 31 days, 30 days, 0, uint64(MAX_SETTLEMENT_FEE_360_DAYS + 1))
        );
    }

    function testTighteningEnforcesAllFieldsAndSentinelAuthorization() public {
        MarketEconomicPolicy memory initial = _policy(100, 10, 31 days, 30 days, 10, 20);
        _setEconomicPolicy(adapter, midnightId, initial);
        uint64 before = adapter.policyEpoch();
        MarketEconomicPolicy memory tighter = _policy(99, 11, 30 days, 29 days, 9, 19);

        vm.prank(address(0xBEEF));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.tightenMarketEconomicPolicy(midnightId, tighter);
        assertEq(adapter.policyEpoch(), before);

        vault.setSentinel(address(this), true);
        adapter.tightenMarketEconomicPolicy(midnightId, tighter);
        assertGt(adapter.policyEpoch(), before);
        uint64 tightenedEpoch = adapter.policyEpoch();

        _assertTighteningRejected(_policy(100, 11, 30 days, 29 days, 9, 19), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 10, 30 days, 29 days, 9, 19), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 11, 31 days, 29 days, 9, 19), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 11, 30 days, 30 days, 9, 19), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 11, 30 days, 29 days, 10, 19), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 11, 30 days, 29 days, 9, 20), tightenedEpoch);
        _assertTighteningRejected(_policy(99, 11, 30 days, 29 days, 9, 19), tightenedEpoch);
    }

    function testMakerSellTickAndExactOneCapBoundaries() public {
        midnight.invokeBuy(adapter, midnightId, midnightMarket, 100, 100, 0, address(adapter), "");
        Offer memory offer = _validBuyOffer();
        assertTrue(adapter.acceptsOffer(offer));
        offer.maxAssets = 0;
        assertFalse(adapter.acceptsOffer(offer));
        offer.maxAssets = 100;
        offer.maxUnits = 1;
        assertFalse(adapter.acceptsOffer(offer));

        offer.buy = false;
        offer.reduceOnly = true;
        offer.receiverIfMakerIsSeller = address(adapter);
        offer.maxAssets = 0;
        offer.maxUnits = 100;
        offer.tick = 10;
        assertTrue(adapter.acceptsOffer(offer));
        offer.tick = 9;
        assertFalse(adapter.acceptsOffer(offer));
        offer.tick = 10;
        offer.tick = 11;
        assertTrue(adapter.acceptsOffer(offer));
        offer.maxUnits = 0;
        assertFalse(adapter.acceptsOffer(offer));
        offer.maxUnits = 100;
        offer.maxAssets = 1;
        assertFalse(adapter.acceptsOffer(offer));
    }

    function testExpiryHorizonAndOrderingBoundaries() public {
        Market memory market = midnightMarket;
        market.maturity = block.timestamp + 35 days;
        bytes32 id = HashLib.hashMarket(market);
        _setEconomicPolicy(adapter, id, _policy(100, 10, 31 days, 30 days, 0, 0));
        _enableMarket(adapter, id);

        Offer memory offer = _validBuyOffer();
        offer.market = market;
        offer.expiry = block.timestamp + 30 days;
        offer.group = keccak256(abi.encode(address(adapter), adapter.policyEpoch()));
        assertTrue(adapter.acceptsOffer(offer));
        offer.expiry = block.timestamp + 30 days + 1;
        assertFalse(adapter.acceptsOffer(offer));
        offer.expiry = block.timestamp;
        assertTrue(adapter.acceptsOffer(offer));
        offer.expiry = block.timestamp - 1;
        assertFalse(adapter.acceptsOffer(offer));
        offer.expiry = market.maturity;
        assertFalse(adapter.acceptsOffer(offer));
    }

    function testNonzeroFeeBoundaries() public {
        Market memory market = midnightMarket;
        market.maturity = block.timestamp + 35 days;
        bytes32 id = HashLib.hashMarket(market);
        _setEconomicPolicy(adapter, id, _policy(100, 10, 31 days, 30 days, 10, 20));
        _enableMarket(adapter, id);

        Offer memory offer = _validBuyOffer();
        offer.market = market;
        offer.expiry = block.timestamp + 1 days;
        offer.continuousFeeCap = 10;
        offer.group = keccak256(abi.encode(address(adapter), adapter.policyEpoch()));
        midnight.setFees(10, 20);
        assertTrue(adapter.acceptsOffer(offer));
        offer.continuousFeeCap = 11;
        assertFalse(adapter.acceptsOffer(offer));
        offer.continuousFeeCap = 10;
        midnight.setFees(11, 20);
        assertFalse(adapter.acceptsOffer(offer));
        midnight.setFees(10, 21);
        assertFalse(adapter.acceptsOffer(offer));
    }
}
