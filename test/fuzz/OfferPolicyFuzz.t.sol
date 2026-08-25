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
    function testFuzzExactMarketAndEconomicGuards(uint128 maxAssets, uint24 tick) public {
        maxAssets = uint128(bound(maxAssets, 1, 1_000_000));
        Offer memory offer = _validBuyOffer(maxAssets);
        assertTrue(adapter.acceptsOffer(offer));

        Offer memory wrongMarket = offer;
        wrongMarket.market.midnight = address(0xBEEF);
        assertFalse(adapter.acceptsOffer(wrongMarket));

        Offer memory wrongLoanToken = offer;
        wrongLoanToken.market.loanToken = address(0xCAFE);
        assertFalse(adapter.acceptsOffer(wrongLoanToken));

        Offer memory wrongTick = offer;
        wrongTick.tick = tick;
        if (tick > 100) assertFalse(adapter.acceptsOffer(wrongTick));
    }
}
