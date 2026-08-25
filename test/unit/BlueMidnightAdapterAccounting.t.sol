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
    bool public returnShortWithdrawal;

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
        if (returnShortWithdrawal) return (assets - 1, assets - 1);
        bytes32 id = Id.unwrap(params.id());
        shares[id] -= assets;
        balances[id][0] -= uint128(assets);
        balances[id][1] -= uint128(assets);
        token.transfer(receiver, assets);
        return (assets, assets);
    }

    function setReturnShortWithdrawal(bool enabled) external {
        returnShortWithdrawal = enabled;
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

    function withdrawable(bytes32 id) external view returns (uint256) {
        return credit[id];
    }

    function withdraw(Market calldata market, uint256 units, address, address receiver) external {
        bytes32 hashId = HashLib.hashMarket(market);
        bytes32 protocolId = IdLib.toId(market);
        credit[hashId] -= uint128(units);
        credit[protocolId] -= uint128(units);
        token.transfer(receiver, units);
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
        blueMarket = MarketParams(address(token), address(1), address(2), address(3), 0);
        MarketEconomicPolicy memory economicPolicy =
            MarketEconomicPolicy({maxBuyTick: 100, minSellTick: 10, maxExpiryHorizon: 30 days});
        adapter = new BlueMidnightAdapter(
            address(vault),
            blueMarket,
            address(midnight),
            address(morpho),
            address(ratifier),
            midnightMarket,
            economicPolicy,
            address(this)
        );
        midnight.setRatifier(ratifier);
        midnightId = adapter.pinnedMidnightMarketHash();
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
        MarketAccounting memory afterSale = adapter.accounting();
        assertEq(afterSale.bookValue, 46);
        assertEq(afterSale.netMaturityClaim, 53);
        assertEq(afterSale.trackedCredit, 46);
        assertEq(adapter.realAssets(), initialNav - 25);
    }

    function testPartialSellReducesClaimExactlyOnce() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 3);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 50, 50, 2);

        MarketAccounting memory a = adapter.accounting();
        assertEq(a.trackedCredit, 50);
        assertEq(a.bookValue, 50);
        assertEq(a.netMaturityClaim, 51);
    }

    function testMultipleFillsAtDifferentTimesAmortizeOnlyUntilMaturity() public {
        uint256 initialAssets = adapter.realAssets();
        vm.warp(midnightMarket.maturity - 20 days);
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        vm.warp(midnightMarket.maturity - 10 days);
        assertEq(adapter.realAssets(), initialAssets + 10);

        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 50, 50, 10);
        MarketAccounting memory afterSecondFill = adapter.accounting();
        assertEq(afterSecondFill.bookValue, 160);
        assertEq(afterSecondFill.netMaturityClaim, 180);

        vm.warp(midnightMarket.maturity);
        assertEq(adapter.realAssets(), initialAssets + 30);
        vm.warp(midnightMarket.maturity + 10 days);
        assertEq(adapter.realAssets(), initialAssets + 30);
    }

    function testImpairmentThenRepaymentSellAndNewBuyNeverRecoverLoss() public {
        vm.warp(midnightMarket.maturity - 20 days);
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        uint256 initialNav = adapter.realAssets();

        midnight.setPosition(midnightId, 70, 0);
        midnight.setPosition(IdLib.toId(midnightMarket), 70, 0);
        assertLt(adapter.realAssets(), initialNav);
        uint256 impairedNav = adapter.realAssets();
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 0, 10, 0);
        assertEq(adapter.realAssets(), impairedNav);

        token.mint(address(midnight), 20);
        midnight.setPosition(midnightId, 70, 0);
        midnight.setPosition(IdLib.toId(midnightMarket), 70, 0);
        adapter.collectRepayment(20);
        assertEq(adapter.accounting().trackedCredit, 50);

        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 45, 50, 0);
        assertEq(adapter.accounting().trackedCredit, 0);
    }

    function testPendingFeeRoundingAndCheckedNarrowing() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 101, 100, 3);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 33, 33, 1);
        MarketAccounting memory rounded = adapter.accounting();
        assertEq(rounded.bookValue, 68); // floor(101 * 67 / 100)
        assertEq(rounded.netMaturityClaim, 69); // protocol claim caps floor(104 * 67 / 100)
        assertEq(rounded.trackedCredit, 67);

        setUp();
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 0, 1, 0);
        midnight.invokeBuy(adapter, midnightId, midnightMarket, 0, 0, type(uint128).max - 1, address(adapter), "");

        setUp();
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 0);
        vm.expectRevert(BlueMidnightAdapter.AccountingOverflow.selector);
        midnight.invokeBuy(adapter, midnightId, midnightMarket, 0, 0, type(uint128).max, address(adapter), "");
    }

    function testIndependentApprovedRootsDoNotRequireCapAccounting() public {
        Offer memory first = _validBuyOffer(100);
        Offer memory second = _validBuyOffer(200);
        bytes32 firstRoot = HashLib.hashOffer(first);
        bytes32 secondRoot = HashLib.hashOffer(second);
        adapter.approveRoot(firstRoot);
        adapter.approveRoot(secondRoot);

        midnight.takeMakerBuy(adapter, first, abi.encode(firstRoot, 0, new bytes32[](0)), 100, 100, 0);
        midnight.takeMakerBuy(adapter, second, abi.encode(secondRoot, 0, new bytes32[](0)), 200, 200, 0);
        assertEq(adapter.accounting().trackedCredit, 300);
    }

    function testOnBuyEnforcesVaultAllocationAndBlueWithdrawalAtomically() public {
        vault.setAllocation(adapter.adapterId(), 50);
        vm.prank(address(midnight));
        vm.expectRevert(BlueMidnightAdapter.ExposureExceeded.selector);
        adapter.onBuy(IdLib.toId(midnightMarket), midnightMarket, 100, 100, 0, address(adapter), "");
        assertEq(adapter.accounting().bookValue, 0);

        vault.setAllocation(adapter.adapterId(), 1_000);
        morpho.setReturnShortWithdrawal(true);
        vm.prank(address(midnight));
        vm.expectRevert(BlueMidnightAdapter.InsufficientLiquidity.selector);
        adapter.onBuy(IdLib.toId(midnightMarket), midnightMarket, 100, 100, 0, address(adapter), "");
        assertEq(adapter.accounting().bookValue, 0);
    }

    function testPauseBlocksNewExposureButAllowsDeallocationRepaymentAndReduceOnlySell() public {
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        token.mint(address(midnight), 20);
        midnight.setPosition(midnightId, 100, 0);
        midnight.setPosition(IdLib.toId(midnightMarket), 100, 0);

        vault.setSentinel(address(this), true);
        adapter.pauseNewExposure(bytes32("pause"));

        vm.prank(address(vault));
        vm.expectRevert(BlueMidnightAdapter.RiskOff.selector);
        adapter.allocate(abi.encode(blueMarket), 1, bytes4(0), address(0));
        vm.expectRevert(BlueMidnightAdapter.ExposureExceeded.selector);
        midnight.invokeBuy(adapter, midnightId, midnightMarket, 0, 1, 0, address(adapter), "");

        vm.prank(address(vault));
        adapter.deallocate(abi.encode(blueMarket), 0, bytes4(0), address(0));
        adapter.collectRepayment(20);
        midnight.takeMakerSell(adapter, midnightId, midnightMarket, 45, 50, 0);
        assertEq(adapter.accounting().trackedCredit, 30);
    }

    function testSharePriceIsContinuousAtFillAndRealization() public {
        uint256 initialAssets = adapter.realAssets();
        uint256 shares = 1e18;
        uint256 initialPrice = initialAssets * 1e18 / shares;
        vm.warp(midnightMarket.maturity - 20 days);
        midnight.takeMakerBuy(adapter, midnightId, midnightMarket, 100, 100, 20);
        assertEq(adapter.realAssets() * 1e18 / shares, initialPrice);

        vm.warp(midnightMarket.maturity);
        assertEq(adapter.realAssets() * 1e18 / shares, (initialAssets + 20) * 1e18 / shares);
    }

    function testQuoterRevocationRejectsNewRootApproval() public {
        bytes32 root = keccak256("revoked-quoter-root");
        vault.setSentinel(address(this), true);
        adapter.pauseNewExposure(bytes32("pause"));
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
        MarketAccounting memory a = adapter.accounting();
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

    function testCuratorCanChangeEachPolicyValueBothDirectionsAndBumpEpoch() public {
        uint64 epoch = adapter.policyEpoch();

        adapter.setMaxBuyTick(99);
        assertEq(adapter.marketEconomicPolicy().maxBuyTick, 99);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMaxBuyTick(100);
        assertEq(adapter.policyEpoch(), ++epoch);

        adapter.setMinSellTick(11);
        assertEq(adapter.marketEconomicPolicy().minSellTick, 11);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMinSellTick(10);
        assertEq(adapter.policyEpoch(), ++epoch);

        adapter.setMaxExpiryHorizon(20 days);
        assertEq(adapter.marketEconomicPolicy().maxExpiryHorizon, 20 days);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMaxExpiryHorizon(30 days);
        assertEq(adapter.policyEpoch(), ++epoch);

        vm.prank(address(0xBEEF));
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.setMaxBuyTick(99);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.setMaxBuyTick(100);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.setMaxBuyTick(type(uint24).max);

        Offer memory offer = _validBuyOffer(100);
        bytes32 root = HashLib.hashOffer(offer);
        adapter.approveRoot(root);
        adapter.setMaxBuyTick(99);
        vm.expectRevert(IPolicySetterRatifier.RootNotApproved.selector);
        midnight.takeMakerBuy(adapter, offer, abi.encode(root, 0, new bytes32[](0)), 100, 100, 0);
    }
}
