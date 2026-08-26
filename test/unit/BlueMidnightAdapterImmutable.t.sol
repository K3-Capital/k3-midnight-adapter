// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";

contract ImmutableToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract RecoveryRatifier {
    mapping(address => mapping(bytes32 => bool)) public approved;

    function setRoot(address maker, bytes32 root, bool enabled) external {
        require(msg.sender == maker, "maker");
        approved[maker][root] = enabled;
    }
}

contract ImmutableVault {
    address public immutable asset;
    address public immutable curator;
    mapping(address => bool) public sentinels;

    constructor(address asset_) {
        asset = asset_;
        curator = msg.sender;
    }

    function isSentinel(address account) external view returns (bool) {
        return sentinels[account];
    }

    function setSentinel(address account, bool enabled) external {
        sentinels[account] = enabled;
    }

    function allocation(bytes32) external pure returns (uint256) {
        return 0;
    }
}

contract BlueMidnightAdapterImmutableTest is Test {
    using MarketParamsLib for MarketParams;
    ImmutableToken internal token;
    ImmutableVault internal vault;
    RecoveryRatifier internal ratifier;
    BlueMidnightAdapter internal adapter;
    MarketParams internal blue;
    Market internal midnightMarket;
    MarketEconomicPolicy internal policy;
    address internal constant MIDNIGHT = address(0x100);
    address internal constant MORPHO = address(0x200);
    address internal constant QUOTER = address(0x400);
    address internal constant ORACLE = address(0x500);
    address internal constant IRM = address(0x600);

    function setUp() public {
        token = new ImmutableToken();
        vault = new ImmutableVault(address(token));
        ratifier = new RecoveryRatifier();
        blue = MarketParams(address(token), address(0), ORACLE, IRM, 0);
        midnightMarket = Market({
            chainId: block.chainid,
            midnight: MIDNIGHT,
            loanToken: address(token),
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        policy = MarketEconomicPolicy(100, 1, 20 days);
        adapter = new BlueMidnightAdapter(
            address(vault), blue, MIDNIGHT, MORPHO, address(ratifier), midnightMarket, policy, QUOTER
        );
    }

    function testConstructorPinsAllDeploymentIdentity() public view {
        assertEq(adapter.parentVault(), address(vault));
        assertEq(adapter.asset(), address(token));
        assertEq(adapter.midnight(), MIDNIGHT);
        assertEq(adapter.morphoBlue(), MORPHO);
        assertEq(adapter.ratifier(), address(ratifier));
        assertEq(adapter.rootApprover(), QUOTER);
        (MarketParams memory configured, bytes32 id) = adapter.blueMarket();
        assertEq(configured.loanToken, blue.loanToken);
        assertEq(configured.oracle, blue.oracle);
        assertEq(id, Id.unwrap(blue.id()));
    }

    function testQuoterRevocationEnablesSentinelRecoveryRootButNotBuys() public {
        bytes32 root = keccak256("recovery-root");
        vm.prank(QUOTER);
        adapter.approveRoot(root);
        vault.setSentinel(address(this), true);
        adapter.pauseNewExposure(bytes32("pause"));
        assertTrue(adapter.newExposurePaused());
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.approveRoot(root);
        vm.prank(QUOTER);
        adapter.revokeRoot(root);
        assertFalse(ratifier.approved(address(adapter), root));
        adapter.approveRecoveryRoot(root);
        assertTrue(ratifier.approved(address(adapter), root));
        assertEq(adapter.buyerAssetsBound(adapter.pinnedMidnightMarketHash()), 0);
    }

    function testCuratorOnlyPolicySettersAllowBothDirectionsAndEpochInvalidation() public {
        uint64 epoch = adapter.policyEpoch();

        vm.prank(QUOTER);
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.setMaxBuyTick(99);

        adapter.setMaxBuyTick(99);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMaxBuyTick(100);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMinSellTick(2);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMinSellTick(1);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMaxExpiryHorizon(10 days);
        assertEq(adapter.policyEpoch(), ++epoch);
        adapter.setMaxExpiryHorizon(20 days);
        assertEq(adapter.policyEpoch(), ++epoch);

        address replacement = address(0x401);
        adapter.setRootApprover(replacement);
        assertEq(adapter.rootApprover(), replacement);
        assertEq(adapter.policyEpoch(), ++epoch);
        bytes32 replacementRoot = keccak256("replacement-root");
        vm.prank(replacement);
        adapter.approveRoot(replacementRoot);
        assertTrue(ratifier.approved(address(adapter), replacementRoot));
        vm.prank(QUOTER);
        vm.expectRevert(BlueMidnightAdapter.Unauthorized.selector);
        adapter.setRootApprover(QUOTER);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.setRootApprover(replacement);

        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.setMaxExpiryHorizon(0);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.setMinSellTick(type(uint24).max);
    }

    function testRiskOffRecoveryRootCannotBeApprovedBeforeEmergency() public {
        vault.setSentinel(address(this), true);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        adapter.approveRecoveryRoot(keccak256("too-early"));
    }

    function testInvalidBlueLoanAssetReverts() public {
        MarketParams memory invalid = blue;
        invalid.loanToken = address(0xBAD);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        new BlueMidnightAdapter(
            address(vault), invalid, MIDNIGHT, MORPHO, address(ratifier), midnightMarket, policy, QUOTER
        );
    }
}
