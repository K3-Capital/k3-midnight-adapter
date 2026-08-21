// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Offer} from "midnight/interfaces/IMidnight.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {PolicySetterRatifier} from "../../src/PolicySetterRatifier.sol";

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
