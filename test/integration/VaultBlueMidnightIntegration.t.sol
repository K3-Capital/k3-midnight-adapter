// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

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

        MarketEconomicPolicy memory policy = MarketEconomicPolicy({
            maxBuyTick: uint24(MAX_TICK), minSellTick: uint24(MAX_TICK), maxExpiryHorizon: uint40(20 days)
        });
        adapter = new BlueMidnightAdapter(
            address(vault),
            blueMarket,
            address(midnight),
            address(morpho),
            address(ratifier),
            midnightMarket,
            policy,
            address(this)
        );
        adapter.approveRoot(bytes32(uint256(1))); // prove quoter wiring before real roots.
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

    function testSharedRatifierSelfAuthorizationAndMakerEpochIsolation() public {
        Market memory secondMarket = midnightMarket;
        secondMarket.maturity += 1 days;
        midnight.touchMarket(secondMarket);
        BlueMidnightAdapter secondAdapter = new BlueMidnightAdapter(
            address(vault),
            blueMarket,
            address(midnight),
            address(morpho),
            address(ratifier),
            secondMarket,
            MarketEconomicPolicy({
                maxBuyTick: uint24(MAX_TICK), minSellTick: uint24(MAX_TICK), maxExpiryHorizon: uint40(20 days)
            }),
            address(this)
        );

        assertEq(address(secondAdapter.ratifier()), address(ratifier));
        assertTrue(midnight.isAuthorized(address(adapter), address(ratifier)));
        assertTrue(midnight.isAuthorized(address(secondAdapter), address(ratifier)));

        bytes32 firstRoot = keccak256("shared-ratifier-first-maker");
        bytes32 secondRoot = keccak256("shared-ratifier-second-maker");
        adapter.approveRoot(firstRoot);
        secondAdapter.approveRoot(secondRoot);
        assertEq(ratifier.approvedAtEpoch(address(adapter), firstRoot), adapter.policyEpoch());
        assertEq(ratifier.approvedAtEpoch(address(secondAdapter), secondRoot), secondAdapter.policyEpoch());
        assertEq(ratifier.approvedAtEpoch(address(adapter), secondRoot), 0);
        assertEq(ratifier.approvedAtEpoch(address(secondAdapter), firstRoot), 0);

        adapter.setMaxBuyTick(uint24(MAX_TICK - 1));
        assertEq(adapter.policyEpoch(), 2);
        assertEq(secondAdapter.policyEpoch(), 1);
        assertEq(ratifier.approvedAtEpoch(address(adapter), firstRoot), 1);
        assertEq(ratifier.approvedAtEpoch(address(secondAdapter), secondRoot), 1);
    }

    function _configureVault() internal {
        _vaultCall(abi.encodeCall(vault.addAdapter, (address(adapter))));
        _vaultCall(abi.encodeCall(vault.setIsAllocator, (allocator, true)));
        bytes32 adapterId = keccak256(abi.encode("this", address(adapter)));
        bytes32 blueId = keccak256(abi.encode("morpho-blue", blueMarket.id()));
        bytes32 midnightId = keccak256(abi.encode("midnight", address(midnight)));
        bytes32 midnightMarketRiskId = keccak256(abi.encode("midnight-market", midnightMarketId));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("this", address(adapter)), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("this", address(adapter)), 1e18)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("morpho-blue", blueMarket.id()), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("morpho-blue", blueMarket.id()), 1e18)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("midnight", address(midnight)), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("midnight", address(midnight)), 1e18)));
        _vaultCall(abi.encodeCall(vault.increaseAbsoluteCap, (abi.encode("midnight-market", midnightMarketId), ASSETS)));
        _vaultCall(abi.encodeCall(vault.increaseRelativeCap, (abi.encode("midnight-market", midnightMarketId), 1e18)));
        assertEq(adapterId, keccak256(abi.encode("this", address(adapter))));
        assertEq(blueId, keccak256(abi.encode("morpho-blue", blueMarket.id())));
        assertEq(midnightId, keccak256(abi.encode("midnight", address(midnight))));
        assertEq(midnightMarketRiskId, keccak256(abi.encode("midnight-market", midnightMarketId)));
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
        vault.allocate(address(adapter), hex"", ASSETS);
        assertEq(shares, ASSETS);
        assertEq(adapter.expectedSupplyAssets(), ASSETS);
        assertGt(morpho.position(blueMarket.id(), address(adapter)).supplyShares, 0);

        Offer memory buy = _buyOffer();
        bytes memory buyData = _approveOffer(buy);
        vm.prank(borrower);
        midnight.take(buy, buyData, UNITS, borrower, borrower, address(0), hex"");
        assertEq(adapter.accounting().trackedCredit, UNITS);
        assertEq(adapter.realAssets(), ASSETS);
        assertEq(token.balanceOf(borrower), UNITS);

        vm.prank(borrower);
        token.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.repay(midnightMarket, UNITS, borrower, address(0), hex"");
        adapter.collectRepayment(UNITS);
        assertEq(adapter.accounting().trackedCredit, 0);
        assertEq(midnight.withdrawable(midnightProtocolId), 0);

        uint256 before = token.balanceOf(depositor);
        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", ASSETS);
        vm.prank(depositor);
        vault.withdraw(ASSETS, depositor, depositor);
        assertEq(token.balanceOf(depositor), before + ASSETS);
        assertEq(vault.totalSupply(), 0);
        assertEq(adapter.expectedSupplyAssets(), 0);
        assertEq(adapter.realAssets(), 0);
    }

    function testVaultDepositWithdrawShareFairnessAroundFillAndRealization() public {
        vm.prank(depositor);
        uint256 shares = vault.deposit(ASSETS, depositor);
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS);
        uint256 priceBeforeFill = vault.convertToAssets(shares);
        assertEq(priceBeforeFill, ASSETS);

        Offer memory buy = _buyOffer();
        bytes memory buyData = _approveOffer(buy);
        vm.prank(borrower);
        midnight.take(buy, buyData, UNITS, borrower, borrower, address(0), hex"");
        assertEq(vault.convertToAssets(shares), priceBeforeFill);

        vm.prank(borrower);
        token.approve(address(midnight), type(uint256).max);
        vm.prank(borrower);
        midnight.repay(midnightMarket, UNITS, borrower, address(0), hex"");
        adapter.collectRepayment(UNITS);
        assertEq(vault.convertToAssets(shares), priceBeforeFill);

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", ASSETS);
        vm.prank(depositor);
        uint256 withdrawn = vault.redeem(shares, depositor, depositor);
        assertEq(withdrawn, ASSETS);
        assertEq(vault.totalSupply(), 0);
    }

    function testRevokedQuoterRecoveryUsesRealRatifierAndMidnight() public {
        vm.prank(depositor);
        vault.deposit(ASSETS, depositor);
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS);

        Offer memory buy = _buyOffer();
        bytes memory buyData = _approveOffer(buy);
        vm.prank(borrower);
        midnight.take(buy, buyData, UNITS, borrower, borrower, address(0), hex"");
        assertEq(adapter.accounting().trackedCredit, UNITS);

        _vaultCall(abi.encodeCall(vault.setIsSentinel, (address(this), true)));
        adapter.pauseNewExposure(bytes32("pause"));
        assertTrue(adapter.newExposurePaused());

        Offer memory sell = _sellOffer(UNITS);
        bytes32 root = HashLib.hashOffer(sell);
        adapter.approveRecoveryRoot(root);
        bytes memory recoveryData = abi.encode(root, uint256(0), new bytes32[](0));

        token.mint(lender, UNITS);
        vm.prank(lender);
        token.approve(address(midnight), type(uint256).max);
        vm.prank(lender);
        midnight.take(sell, recoveryData, UNITS, lender, address(0), address(0), hex"");
        assertEq(adapter.accounting().trackedCredit, 0);
    }

    function testOtherwiseIdenticalOtherMarketIsRejected() public view {
        Offer memory offer = _buyOffer();
        offer.market.maturity += 1;
        assertFalse(adapter.acceptsOffer(offer));
        assertTrue(HashLib.hashMarket(offer.market) != adapter.pinnedMidnightMarketHash());
    }
}
