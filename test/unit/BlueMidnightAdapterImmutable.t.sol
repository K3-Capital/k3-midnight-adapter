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
    BlueMidnightAdapter internal adapter;
    MarketParams internal blue;
    Market internal midnightMarket;
    MarketEconomicPolicy internal policy;
    address internal constant MIDNIGHT = address(0x100);
    address internal constant MORPHO = address(0x200);
    address internal constant RATIFFER = address(0x300);
    address internal constant QUOTER = address(0x400);
    address internal constant ORACLE = address(0x500);
    address internal constant IRM = address(0x600);

    function setUp() public {
        token = new ImmutableToken();
        vault = new ImmutableVault(address(token));
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
        policy = MarketEconomicPolicy(100, 1, 30 days, 20 days, 0, 0, true);
        adapter =
            new BlueMidnightAdapter(address(vault), blue, MIDNIGHT, MORPHO, RATIFFER, midnightMarket, policy, QUOTER);
    }

    function testConstructorPinsAllDeploymentIdentity() public view {
        assertEq(adapter.parentVault(), address(vault));
        assertEq(adapter.asset(), address(token));
        assertEq(adapter.midnight(), MIDNIGHT);
        assertEq(adapter.morphoBlue(), MORPHO);
        assertEq(adapter.ratifier(), RATIFFER);
        assertEq(adapter.approvedQuoter(), QUOTER);
        (MarketParams memory configured, bytes32 id) = adapter.blueMarket();
        assertEq(configured.loanToken, blue.loanToken);
        assertEq(configured.oracle, blue.oracle);
        assertEq(id, Id.unwrap(blue.id()));
        assertTrue(adapter.blueMarketConfigured());
        assertTrue(adapter.marketEnabled());
    }

    function testQuoterRevocationAndRiskOffAreMonotonic() public {
        vault.setSentinel(address(this), true);
        adapter.revokeQuoter(QUOTER);
        assertFalse(adapter.isQuoter(QUOTER));
        vm.prank(address(this));
        adapter.riskOff(bytes32("incident"));
        assertTrue(adapter.riskOffActive());
        assertEq(adapter.buyerAssetsBound(adapter.pinnedMidnightMarketHash()), 0);
    }

    function testInvalidBlueLoanAssetReverts() public {
        MarketParams memory invalid = blue;
        invalid.loanToken = address(0xBAD);
        vm.expectRevert(BlueMidnightAdapter.InvalidValue.selector);
        new BlueMidnightAdapter(address(vault), invalid, MIDNIGHT, MORPHO, RATIFFER, midnightMarket, policy, QUOTER);
    }
}
