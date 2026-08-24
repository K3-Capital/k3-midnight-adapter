// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {ExitToken, ExitVault, ExitMorpho, ExitMidnight} from "../unit/BlueMidnightAdapterExit.t.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";

/// @notice Stateful caller harness for the Stage 6 adapter boundary.
/// @dev Every target method uses the same valid market and impersonates the caller
///      authorized by the production adapter (vault or sentinel).
contract Stage6AdapterHandler is Test {
    ExitToken public immutable token;
    ExitVault public immutable vault;
    ExitMorpho public immutable morpho;
    ExitMidnight public immutable midnight;
    BlueMidnightAdapter public immutable adapter;
    MarketParams public blueMarket;
    Market public midnightMarket;
    bytes32 public immutable midnightMarketId;
    address internal constant SENTINEL = address(0xBEEF);

    constructor(
        ExitToken token_,
        ExitVault vault_,
        ExitMorpho morpho_,
        ExitMidnight midnight_,
        BlueMidnightAdapter adapter_,
        MarketParams memory blueMarket_,
        Market memory midnightMarket_
    ) {
        token = token_;
        vault = vault_;
        morpho = morpho_;
        midnight = midnight_;
        adapter = adapter_;
        blueMarket = blueMarket_;
        midnightMarket = midnightMarket_;
        midnightMarketId = HashLib.hashMarket(midnightMarket_);
    }

    function allocate(uint256 requested) external {
        if (adapter.riskOffActive()) return;
        uint256 assets = requested % 101;
        token.mint(address(vault), assets);
        vm.prank(address(vault));
        token.transfer(address(adapter), assets);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(blueMarket), assets, bytes4(0), address(0));
    }

    function deallocate(uint256 requested) external {
        uint256 available = adapter.expectedSupplyAssets();
        uint256 assets = available == 0 ? 0 : requested % (available + 1);
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(blueMarket), assets, bytes4(0), address(0));
    }

    function buy(uint256 requested) external {
        if (adapter.riskOffActive()) return;
        uint256 available = adapter.expectedSupplyAssets();
        uint256 assets = available == 0 ? 0 : requested % (available + 1);
        if (assets == 0) return;
        midnight.invokeBuy(address(adapter), midnightMarket, assets, assets);
    }

    function repay(uint256 requested) external {
        uint256 credit = adapter.marketAccounting(midnightMarketId).trackedCredit;
        if (credit == 0) return;
        uint256 units = requested % (credit + 1);
        if (units == 0) return;
        token.mint(address(midnight), units);
        midnight.seed(midnightMarket, credit, units, 0);
        adapter.collectRepayments(_markets(midnightMarket), _units(units));
    }

    function sell(uint256 requested) external {
        uint256 credit = adapter.marketAccounting(midnightMarketId).trackedCredit;
        if (credit == 0) return;
        uint256 units = requested % (credit + 1);
        if (units == 0) return;
        token.mint(address(midnight), units);
        midnight.seed(midnightMarket, credit, 0, units);
        midnight.take(_offer(), hex"", units, address(adapter), address(adapter), address(adapter), hex"");
    }

    function riskOff() external {
        vault.setSentinel(SENTINEL, true);
        vm.prank(SENTINEL);
        adapter.riskOff(bytes32("handler-risk-off"));
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
            maxAssets: type(uint128).max,
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

contract Stage6HandlerInvariantTest is Test {
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;
    ExitMidnight midnight;
    BlueMidnightAdapter adapter;
    Stage6AdapterHandler handler;
    MarketParams blueMarket;
    Market midnightMarket;
    bytes32 midnightMarketId;

    function setUp() public {
        token = new ExitToken();
        vault = new ExitVault(address(token));
        morpho = new ExitMorpho(address(token));
        midnight = new ExitMidnight(address(token));
        adapter = new BlueMidnightAdapter(address(vault), address(midnight), address(morpho), address(5));
        blueMarket = MarketParams(address(token), address(1), address(2), address(3), 0);
        _execute(abi.encodeWithSelector(adapter.setBlueMarket.selector, blueMarket));

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
        _execute(abi.encodeWithSelector(adapter.setMarketEconomicPolicy.selector, midnightMarketId, _policy()));
        _execute(abi.encodeWithSelector(adapter.setMarketPolicy.selector, midnightMarketId, 1_000_000, 1_000_000, true));
        _execute(abi.encodeWithSelector(adapter.setExposureCaps.selector, 1_000_000, 1_000_000));

        handler = new Stage6AdapterHandler(token, vault, morpho, midnight, adapter, blueMarket, midnightMarket);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.allocate.selector;
        selectors[1] = handler.deallocate.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.sell.selector;
        selectors[5] = handler.riskOff.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyAndBookValueHaveTokenBacking() public view {
        assertLe(adapter.expectedSupplyAssets(), token.balanceOf(address(morpho)));
        assertLe(adapter.realAssets(), token.balanceOf(address(adapter)) + token.balanceOf(address(morpho)) + token.balanceOf(address(midnight)));
    }

    function invariant_riskOffCannotBeBypassed() public view {
        if (adapter.riskOffActive()) assertEq(adapter.buyerAssetsBound(midnightMarketId), 0);
    }

    function _execute(bytes memory data) internal {
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        (bool ok,) = address(adapter).call(data);
        assertTrue(ok);
    }

    function _policy() internal pure returns (MarketEconomicPolicy memory policy) {
        policy = MarketEconomicPolicy(1_000, 0, 30 days, 20 days, 0, 0, true);
    }
}
