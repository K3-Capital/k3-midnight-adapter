// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Market, Offer, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {MarketAccounting} from "../../src/types/AdapterTypes.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {CALLBACK_SUCCESS} from "midnight/libraries/ConstantsLib.sol";

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

    constructor(address token_) {
        token = token_;
        curator = msg.sender;
    }

    function asset() external view returns (address) {
        return token;
    }

    function isSentinel(address) external pure returns (bool) {
        return false;
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
        return adapter.onBuy(id, market, assets, units, fee, buyer, data);
    }

    function updatePositionView(Market calldata, bytes32, address) external pure returns (uint128, uint128, uint128) {
        return (type(uint128).max, 0, 0);
    }
}

contract BlueMidnightAdapterAccountingTest is Test {
    using MarketParamsLib for MarketParams;
    AccountingTokenMock token;
    AccountingVaultMock vault;
    AccountingMorphoMock morpho;
    AccountingMidnightMock midnight;
    BlueMidnightAdapter adapter;
    MarketParams blueMarket;
    Market midnightMarket;
    bytes32 midnightId;

    function setUp() public {
        token = new AccountingTokenMock();
        vault = new AccountingVaultMock(address(token));
        morpho = new AccountingMorphoMock(address(token));
        midnight = new AccountingMidnightMock();
        adapter = new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(0x4444));
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
        token.mint(address(morpho), 1_000_000);
        morpho.setBalances(blueMarket.id(), 1_000_000, 1_000_000, 0, 1_000_000);
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
            address(0x4444),
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
            address(0x4444),
            false,
            0,
            100,
            0
        );

        assertTrue(adapter.acceptsOffer(offer));
    }

    function _validBuyOffer() internal view returns (Offer memory) {
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
            address(0x4444),
            false,
            0,
            100,
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
}
