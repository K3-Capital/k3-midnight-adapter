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
import {AdapterTestMarket} from "../utils/AdapterTestMarket.sol";

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
    mapping(bytes32 => uint256) public allocations;

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

    function allocation(bytes32 id) external view returns (uint256) {
        return allocations[id];
    }

    function setAllocation(bytes32 id, uint256 amount) external {
        allocations[id] = amount;
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
        midnightMarket = AdapterTestMarket.make(address(midnight), address(token));
        adapter = new BlueMidnightAdapter(
            address(vault), address(midnight), address(morpho), address(ratifier), midnightMarket
        );
        midnight.setRatifier(ratifier);
        blueMarket = MarketParams(address(token), address(1), address(2), address(3), 0);
        bytes memory blueData = abi.encodeWithSelector(adapter.setBlueMarket.selector, blueMarket);
        adapter.submit(blueData);
        vm.warp(adapter.executableAt(blueData));
        adapter.setBlueMarket(blueMarket);
        midnightId = adapter.pinnedMidnightMarketHash();
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
            abi.encodeWithSelector(adapter.setMarketEconomicPolicy.selector, economicPolicy);
        adapter.submit(economicPolicyData);
        vm.warp(adapter.executableAt(economicPolicyData));
        adapter.setMarketEconomicPolicy(economicPolicy);
        bytes memory quoterData = abi.encodeWithSelector(adapter.setQuoter.selector, address(this), true);
        adapter.submit(quoterData);
        vm.warp(adapter.executableAt(quoterData));
        adapter.setQuoter(address(this), true);
        vault.setAllocation(adapter.adapterId(), 1_000_000);
        token.mint(address(morpho), 1_000_000);
        morpho.setBalances(blueMarket.id(), 1_000_000, 1_000_000_000_000, 0, 1_000_000_000_000);
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

    function testBuyAccruesClaimFromFillTimeUntilMaturity() public {
        uint256 fillTime = midnightMarket.maturity - 20 days;
        vm.warp(fillTime);
        uint256 initialNav = adapter.realAssets();

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        _assertAccounting(midnightId, 100, 120, 100, uint40(fillTime), true);
        assertEq(adapter.realAssets(), initialNav);

        vm.warp(fillTime + 10 days);
        assertEq(adapter.realAssets(), initialNav + 10);
        vm.warp(midnightMarket.maturity);
        assertEq(adapter.realAssets(), initialNav + 20);
        vm.warp(midnightMarket.maturity + 1 days);
        assertEq(adapter.realAssets(), initialNav + 20);
    }

    function testLossSynchronizationAndPartialSellPreserveLoss() public {
        uint256 fillTime = midnightMarket.maturity - 20 days;
        vm.warp(fillTime);
        uint256 initialNav = adapter.realAssets();
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 101, 100, 23);
        midnight.setPosition(IdLib.toId(midnightMarket), 83, 7);
        assertEq(adapter.realAssets(), initialNav - 11);

        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 30, 37, 0);
        MarketAccounting memory afterSale = adapter.marketAccounting(midnightId);
        assertEq(afterSale.bookValue, 46);
        assertEq(afterSale.netMaturityClaim, 53);
        assertEq(afterSale.trackedCredit, 46);
        assertEq(adapter.realAssets(), initialNav - 25);
    }

    function testPartialSellReducesClaimExactlyOnce() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 3);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 50, 50, 2);

        MarketAccounting memory a = adapter.marketAccounting(midnightId);
        assertEq(a.trackedCredit, 50);
        assertEq(a.bookValue, 50);
        assertEq(a.netMaturityClaim, 51);
    }

    function testQuoterRevocationRejectsNewRootApproval() public {
        bytes32 root = keccak256("revoked-quoter-root");
        vault.setSentinel(address(this), true);
        adapter.revokeQuoter(address(this));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.approveRoot(root);
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
        adapter.tightenMarketEconomicPolicy(tighter);
        assertGt(adapter.policyEpoch(), before);
        MarketEconomicPolicy memory looser = tighter;
        looser.maxBuyTick = 100;
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.tightenMarketEconomicPolicy(looser);
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
        bytes memory data = abi.encodeWithSelector(target.setMarketEconomicPolicy.selector, policy);
        target.submit(data);
        vm.warp(target.executableAt(data));
        target.setMarketEconomicPolicy(policy);
    }

    function _enableMarket(BlueMidnightAdapter, bytes32) internal pure {}

    function _rejectEconomicPolicy(BlueMidnightAdapter target, MarketEconomicPolicy memory policy) internal {
        uint64 before = target.policyEpoch();
        bytes memory data = abi.encodeWithSelector(target.setMarketEconomicPolicy.selector, policy);
        target.submit(data);
        vm.warp(target.executableAt(data));
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        target.setMarketEconomicPolicy(policy);
        assertEq(target.policyEpoch(), before);
        (uint24 maxBuyTick,,,,,, bool configured) = target.marketEconomicPolicy();
        assertEq(maxBuyTick, 0);
        assertFalse(configured);
    }

    function _assertTighteningRejected(MarketEconomicPolicy memory policy, uint64 expectedEpoch) internal {
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.tightenMarketEconomicPolicy(policy);
        assertEq(adapter.policyEpoch(), expectedEpoch);
    }

    function testTighteningEnforcesAllFieldsAndSentinelAuthorization() public {
        MarketEconomicPolicy memory initial = _policy(100, 10, 31 days, 30 days, 10, 20);
        _setEconomicPolicy(adapter, midnightId, initial);
        uint64 before = adapter.policyEpoch();
        MarketEconomicPolicy memory tighter = _policy(99, 11, 30 days, 29 days, 9, 19);

        vm.prank(address(0xBEEF));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.tightenMarketEconomicPolicy(tighter);
        assertEq(adapter.policyEpoch(), before);

        vault.setSentinel(address(this), true);
        adapter.tightenMarketEconomicPolicy(tighter);
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
}
