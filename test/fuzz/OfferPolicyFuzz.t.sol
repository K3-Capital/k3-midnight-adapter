// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Offer} from "midnight/interfaces/IMidnight.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {PolicySetterRatifier} from "../../src/PolicySetterRatifier.sol";
import {BlueMidnightAdapterAccountingTest} from "../unit/BlueMidnightAdapterAccounting.t.sol";

interface IPolicyEpochMaker {
    function setEpoch(uint64 epoch) external;
}

contract FuzzPolicyMaker {
    uint64 public epoch = 1;
    bool public accepted = true;

    function setEpoch(uint64 nextEpoch) external {
        epoch = nextEpoch;
    }

    function acceptsOffer(Offer calldata) external view returns (bool) {
        return accepted;
    }

    function policyEpoch() external view returns (uint64) {
        return epoch;
    }
}

contract FuzzMidnight {
    function ratify(PolicySetterRatifier ratifier, Offer calldata offer, bytes calldata data)
        external
        view
        returns (bytes32)
    {
        return ratifier.isRatified(offer, data, address(0));
    }
}

contract OfferPolicyFuzzTest is Test {
    function testFuzzApprovedRootUsesCurrentEpoch(uint64 nextEpoch, uint256 maxAssets) public {
        vm.assume(nextEpoch != 0);
        vm.assume(maxAssets <= type(uint128).max);
        FuzzMidnight midnight = new FuzzMidnight();
        PolicySetterRatifier ratifier = new PolicySetterRatifier(address(midnight));
        FuzzPolicyMaker maker = new FuzzPolicyMaker();
        Offer memory offer;
        offer.maker = address(maker);
        offer.ratifier = address(ratifier);
        offer.market.chainId = block.chainid;
        offer.market.midnight = address(midnight);
        // forge-lint: disable-next-line(unsafe-typecast)
        offer.maxAssets = uint128(maxAssets);
        bytes32 root = HashLib.hashOffer(offer);

        maker.setEpoch(nextEpoch);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);
        assertEq(
            midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0))),
            keccak256("morpho.midnight.callbackSuccess")
        );
    }
}

contract OfferPolicyAdapterGuardFuzzTest is BlueMidnightAdapterAccountingTest {
    function testFuzzRetainedTheftAndEconomicGuards(uint8 guard, uint128 maxAssets, uint24 tick) public {
        guard = uint8(bound(guard, 0, 12));
        maxAssets = uint128(bound(maxAssets, 1, 1_000_000));
        Offer memory offer = _validBuyOffer(maxAssets);
        if (guard == 0) offer.maker = address(0xBEEF);
        if (guard == 1) offer.ratifier = address(0xBEEF);
        if (guard == 2) offer.callback = address(0xBEEF);
        if (guard == 3) offer.market.chainId = block.chainid + 1;
        if (guard == 4) offer.start = block.timestamp + 1;
        if (guard == 5) offer.expiry = offer.market.maturity;
        if (guard == 6) offer.group = bytes32(uint256(1));
        if (guard == 7) offer.continuousFeeCap = 1;
        if (guard == 8) offer.tick = tick > 100 ? tick : uint24(101);
        if (guard == 9) {
            offer.maxAssets = 0;
            offer.maxUnits = 1;
        }
        if (guard == 10) {
            offer.receiverIfMakerIsSeller = address(0xBEEF);
            offer.reduceOnly = true;
        }
        if (guard == 11) offer.market.midnight = address(0xBEEF);
        if (guard == 12) offer.market.loanToken = address(0xBEEF);
        assertFalse(adapter.acceptsOffer(offer));
    }
}
