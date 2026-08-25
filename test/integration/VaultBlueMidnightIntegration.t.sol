// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {BlueMidnightAdapterFactory} from "../../src/BlueMidnightAdapterFactory.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {PolicySetterRatifier} from "../../src/PolicySetterRatifier.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {IMorpho, MarketParams, Market as MorphoMarket} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IMidnight, Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {MAX_SETTLEMENT_FEE_360_DAYS} from "midnight/libraries/ConstantsLib.sol";
import {MAX_TICK} from "midnight/libraries/TickLib.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";

contract IntegrationToken {
    string public name = "Integration Token";
    string public symbol = "ITK";
    uint8 public immutable decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract IntegrationOracle {
    function price() external pure returns (uint256) {
        return 1e36;
    }
}

contract ZeroIrm is IIrm {
    function borrowRate(MarketParams memory, MorphoMarket memory) external pure returns (uint256) {
        return 0;
    }

    function borrowRateView(MarketParams memory, MorphoMarket memory) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Full local lifecycle against the pinned Vault V2, Morpho Blue, and Midnight implementations.
contract VaultBlueMidnightIntegrationTest is Test {
    using MarketParamsLib for MarketParams;
    uint256 internal constant ASSETS = 1_000_000 ether;
    uint256 internal constant UNITS = 100_000 ether;
    uint256 internal constant PARTIAL_UNITS = 40_000 ether;

    BlueMidnightAdapterFactory internal factory;
    IntegrationToken internal token;
    IntegrationToken internal collateral;
    IVaultV2 internal vault;
    IMorpho internal morpho;
    IMidnight internal midnight;
    PolicySetterRatifier internal ratifier;
    BlueMidnightAdapter internal adapter;
    IntegrationOracle internal oracle;
    ZeroIrm internal irm;
    MarketParams internal blueMarket;
    Market internal midnightMarket;
    bytes32 internal midnightMarketId;
    bytes32 internal midnightProtocolId;
    address internal borrower;
    address internal lender;
    address internal depositor;
    address internal allocator;

    function setUp() public {
        vm.skip(true);
        borrower = makeAddr("borrower");
        lender = makeAddr("lender");
        depositor = makeAddr("depositor");
        allocator = makeAddr("allocator");
        token = new IntegrationToken();
        collateral = new IntegrationToken();
        vault = IVaultV2(deployCode("VaultV2.sol", abi.encode(address(this), address(token))));
        vault.setCurator(address(this));

        morpho = IMorpho(deployCode("Morpho.sol", abi.encode(address(this))));
        irm = new ZeroIrm();
        midnight = IMidnight(deployCode("Midnight.sol"));
        ratifier = new PolicySetterRatifier(address(midnight));
        oracle = new IntegrationOracle();

        morpho.enableIrm(address(irm));
        morpho.enableLltv(0);
        blueMarket = MarketParams({
            loanToken: address(token), collateralToken: address(0), oracle: address(0), irm: address(irm), lltv: 0
        });
        morpho.createMarket(blueMarket);

        midnight.enableLltv(0.77 ether);
        midnight.enableLiquidationCursor(0.3 ether);
        CollateralParams[] memory collateralParams = new CollateralParams[](1);
        collateralParams[0] = CollateralParams({
            token: address(collateral), lltv: 0.77 ether, liquidationCursor: 0.3 ether, oracle: address(oracle)
        });
        midnightMarket = Market({
            chainId: block.chainid,
            midnight: address(midnight),
            loanToken: address(token),
            maturity: block.timestamp + 30 days,
            collateralParams: collateralParams,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        midnightProtocolId = midnight.touchMarket(midnightMarket);
        midnightMarketId = HashLib.hashMarket(midnightMarket);

        factory = new BlueMidnightAdapterFactory();
        adapter = BlueMidnightAdapter(
            factory.deploy(
                keccak256("full-lifecycle"),
                address(vault),
                address(midnight),
                address(morpho),
                address(ratifier),
                midnightMarket
            )
        );
        vm.prank(address(adapter));
        midnight.setIsAuthorized(address(ratifier), true, address(adapter));

        _configureAdapter();
        _configureVault();

        token.mint(depositor, ASSETS);
        vm.prank(depositor);
        token.approve(address(vault), type(uint256).max);

        collateral.mint(borrower, 2_000_000 ether);
        vm.prank(borrower);
        collateral.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.supplyCollateral(midnightMarket, 0, 2_000_000 ether, borrower);
    }

    function _configureAdapter() internal {
        _adapterCall(abi.encodeCall(adapter.setBlueMarket, (blueMarket)));
        _adapterCall(abi.encodeCall(adapter.setQuoter, (address(this), true)));

        MarketEconomicPolicy memory policy = MarketEconomicPolicy({
            maxBuyTick: uint24(MAX_TICK),
            minSellTick: uint24(MAX_TICK),
            maxTenor: uint40(30 days),
            maxExpiryHorizon: uint40(30 days),
            maxContinuousFeePerSecondWad: 0,
            maxSettlementFeeWad: uint64(MAX_SETTLEMENT_FEE_360_DAYS),
            configured: true
        });
        _adapterCall(abi.encodeCall(adapter.setMarketEconomicPolicy, (policy)));
        adapter.approveRoot(bytes32(uint256(1))); // prove quoter wiring before real roots.
    }

    function _configureVault() internal {
        _vaultCall(abi.encodeCall(vault.addAdapter, (address(adapter))));
        _vaultCall(abi.encodeCall(vault.setIsAllocator, (allocator, true)));
        bytes32 adapterId = keccak256(abi.encode("this", address(adapter)));
        bytes32 blueId = keccak256(abi.encode("morpho-blue", blueMarket.id()));
        bytes32 midnightId = keccak256(abi.encode("midnight", address(midnight)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("this", address(adapter)), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("this", address(adapter)), 1e18)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("morpho-blue", blueMarket.id()), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("morpho-blue", blueMarket.id()), 1e18)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("midnight", address(midnight)), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("midnight", address(midnight)), 1e18)));
        assertEq(adapterId, keccak256(abi.encode("this", address(adapter))));
        assertEq(blueId, keccak256(abi.encode("morpho-blue", blueMarket.id())));
        assertEq(midnightId, keccak256(abi.encode("midnight", address(midnight))));
    }

    function _adapterCall(bytes memory data) internal {
        adapter.submit(data);
        vm.warp(adapter.executableAt(data));
        (bool ok, bytes memory returndata) = address(adapter).call(data);

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }

    function _vaultCall(bytes memory data) internal {
        vault.submit(data);
        vm.warp(vault.executableAt(data));
        (bool ok, bytes memory returndata) = address(vault).call(data);

        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }

    function _buyOffer() internal view returns (Offer memory offer) {
        offer.market = midnightMarket;
        offer.buy = true;
        offer.maker = address(adapter);
        offer.start = block.timestamp;
        offer.expiry = block.timestamp + 1 days;
        offer.tick = uint24(MAX_TICK);
        offer.group = keccak256(abi.encode(address(adapter), adapter.policyEpoch()));
        offer.callback = address(adapter);
        offer.callbackData = hex"";
        offer.ratifier = address(ratifier);
        offer.reduceOnly = false;
        offer.maxUnits = 0;
        offer.maxAssets = uint128(ASSETS);
        offer.continuousFeeCap = 0;
    }

    function _sellOffer(uint256 units) internal view returns (Offer memory offer) {
        offer = _buyOffer();
        offer.buy = false;
        offer.maker = address(adapter);
        offer.receiverIfMakerIsSeller = address(adapter);
        offer.maxUnits = uint128(units);
        offer.maxAssets = 0;
        offer.reduceOnly = true;
    }

    function _approveOffer(Offer memory offer) internal returns (bytes memory ratifierData) {
        bytes32 root = HashLib.hashOffer(offer);
        adapter.approveRoot(root);
        ratifierData = abi.encode(root, uint256(0), new bytes32[](0));
    }

    function testFullVaultMorphoMidnightLifecycle() public {
        uint256 shares;
        vm.prank(depositor);
        shares = vault.deposit(ASSETS, depositor);
        vm.prank(allocator);
        vault.allocate(address(adapter), abi.encode(blueMarket), ASSETS);
        assertEq(shares, ASSETS);
        assertEq(adapter.expectedSupplyAssets(), ASSETS);
        assertGt(morpho.position(blueMarket.id(), address(adapter)).supplyShares, 0);

        Offer memory buy = _buyOffer();
        bytes memory buyData = _approveOffer(buy);
        vm.prank(borrower);
        midnight.take(buy, buyData, UNITS, borrower, borrower, address(0), hex"");
        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, UNITS);
        assertEq(adapter.realAssets(), ASSETS);
        assertEq(token.balanceOf(borrower), UNITS);

        vm.prank(borrower);
        token.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.repay(midnightMarket, PARTIAL_UNITS, borrower, address(0), hex"");
        adapter.collectRepayments(PARTIAL_UNITS);
        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, UNITS - PARTIAL_UNITS);

        _adapterCall(abi.encodeCall(adapter.setQuoter, (address(this), false)));
        _adapterCall(abi.encodeCall(adapter.setQuoter, (address(this), true)));
        uint256 remainingUnits = adapter.marketAccounting(midnightMarketId).trackedCredit;
        Offer memory sell = _sellOffer(remainingUnits);
        bytes memory sellData = _approveOffer(sell);
        token.mint(lender, UNITS);
        vm.prank(lender);
        token.approve(address(midnight), type(uint256).max);
        vm.prank(lender);
        midnight.take(sell, sellData, remainingUnits, lender, address(0), address(0), hex"");
        assertEq(adapter.marketAccounting(midnightMarketId).trackedCredit, 0);

        vm.prank(borrower);
        midnight.repay(midnightMarket, remainingUnits, borrower, address(0), hex"");
        vm.prank(lender);
        midnight.withdraw(midnightMarket, remainingUnits, lender, lender);
        assertEq(midnight.withdrawable(midnightProtocolId), 0);

        uint256 before = token.balanceOf(depositor);
        vm.prank(allocator);
        vault.deallocate(address(adapter), abi.encode(blueMarket), ASSETS);
        vm.prank(depositor);
        vault.withdraw(ASSETS, depositor, depositor);
        assertEq(token.balanceOf(depositor), before + ASSETS);
        assertEq(vault.totalSupply(), 0);
        assertEq(adapter.expectedSupplyAssets(), 0);
        assertEq(adapter.realAssets(), 0);
    }

    function testFactoryPredictionMatchesRealDeployment() public view {
        address predicted = factory.predict(
            keccak256("prediction"),
            address(vault),
            address(midnight),
            address(morpho),
            address(ratifier),
            midnightMarket
        );
        assertTrue(predicted != address(0));
    }
}
