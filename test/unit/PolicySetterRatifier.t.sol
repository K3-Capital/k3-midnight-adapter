// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Offer} from "midnight/interfaces/IMidnight.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {CALLBACK_SUCCESS} from "midnight/libraries/ConstantsLib.sol";
import {PolicySetterRatifier} from "../../src/PolicySetterRatifier.sol";
import {IOfferPolicy} from "../../src/interfaces/IOfferPolicy.sol";
import {IPolicySetterRatifier} from "../../src/interfaces/IPolicySetterRatifier.sol";

contract PolicyMaker is IOfferPolicy {
    uint64 public epoch = 1;
    bool public accepted = true;

    function setEpoch(uint64 nextEpoch) external {
        epoch = nextEpoch;
    }

    function setAccepted(bool nextAccepted) external {
        accepted = nextAccepted;
    }

    function acceptsOffer(Offer calldata) external view returns (bool) {
        return accepted;
    }

    function policyEpoch() external view returns (uint64) {
        return epoch;
    }
}

contract EpochOnlyProvider {
    function policyEpoch() external pure returns (uint64) {
        return 1;
    }
}

contract MidnightCaller {
    function ratify(PolicySetterRatifier ratifier, Offer calldata offer, bytes calldata data)
        external
        view
        returns (bytes32)
    {
        return ratifier.isRatified(offer, data, address(0));
    }
}

contract PolicySetterRatifierTest is Test {
    PolicySetterRatifier internal ratifier;
    PolicyMaker internal maker;
    MidnightCaller internal midnight;
    Offer internal offer;

    function setUp() public {
        midnight = new MidnightCaller();
        ratifier = new PolicySetterRatifier(address(midnight));
        maker = new PolicyMaker();
        offer.maker = address(maker);
        offer.ratifier = address(ratifier);
        offer.market.chainId = block.chainid;
        offer.market.midnight = address(midnight);
        offer.market.loanToken = address(0xBEEF);
        offer.buy = true;
        offer.maxUnits = 1;
        offer.maxAssets = 1;
    }

    function testMakerOnlyRootApprovalAndRatification() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);

        bytes32 result = midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
        assertEq(result, CALLBACK_SUCCESS);
        assertEq(ratifier.approvedAtEpoch(address(maker), root), 1);
    }

    function testQuoterCannotApproveRoot() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.expectRevert(IPolicySetterRatifier.UnauthorizedCaller.selector);
        ratifier.setRoot(address(maker), root, true);
    }

    function testOldRootFailsAfterEpochIncrement() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);
        maker.setEpoch(2);

        vm.expectRevert(IPolicySetterRatifier.RootNotApproved.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testRejectedOfferFails() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);
        maker.setAccepted(false);

        vm.expectRevert(IPolicySetterRatifier.OfferRejected.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testWrongCallerFails() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);

        vm.expectRevert(IPolicySetterRatifier.UnauthorizedCaller.selector);
        ratifier.isRatified(offer, abi.encode(root, 0, new bytes32[](0)), address(0));
    }

    function testInvalidProofFails() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);
        offer.maxAssets = 2;

        vm.expectRevert(IPolicySetterRatifier.InvalidProof.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testMalformedRatifierDataFails() public {
        vm.expectRevert(IPolicySetterRatifier.MalformedRatifierData.selector);
        midnight.ratify(ratifier, offer, hex"00");
    }

    function testMalformedOffsetAndTruncationFail() public {
        bytes32 root = HashLib.hashOffer(offer);
        bytes memory badOffset = abi.encode(root, 0, uint256(64), uint256(0));
        bytes memory truncated = abi.encode(root, 0, uint256(96), uint256(1));

        vm.expectRevert(IPolicySetterRatifier.MalformedRatifierData.selector);
        midnight.ratify(ratifier, offer, badOffset);
        vm.expectRevert(IPolicySetterRatifier.MalformedRatifierData.selector);
        midnight.ratify(ratifier, offer, truncated);
    }

    function testOutOfRangeLeafIndexIsInvalidProof() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);

        vm.expectRevert(IPolicySetterRatifier.InvalidProof.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 1, new bytes32[](0)));
    }

    function testRootRevocationFails() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.startPrank(address(maker));
        ratifier.setRoot(address(maker), root, true);
        ratifier.setRoot(address(maker), root, false);
        vm.stopPrank();

        vm.expectRevert(IPolicySetterRatifier.RootNotApproved.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testZeroEpochCannotApproveRoot() public {
        bytes32 root = HashLib.hashOffer(offer);
        maker.setEpoch(0);
        vm.prank(address(maker));
        vm.expectRevert(IPolicySetterRatifier.PolicyEpochUnset.selector);
        ratifier.setRoot(address(maker), root, true);
    }

    function testInvalidPolicyProviderIsNormalized() public {
        EpochOnlyProvider provider = new EpochOnlyProvider();
        offer.maker = address(provider);
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(provider));
        ratifier.setRoot(address(provider), root, true);
        vm.expectRevert(IPolicySetterRatifier.InvalidPolicyProvider.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testCompatibilitySetterEmitsAndBindsMaker() public {
        bytes32 root = HashLib.hashOffer(offer);
        vm.expectEmit(true, true, true, true, address(ratifier));
        emit IPolicySetterRatifier.SetIsRootRatified(address(maker), address(maker), root, true);
        vm.prank(address(maker));
        ratifier.setIsRootRatified(address(maker), root, true);
        assertEq(ratifier.approvedAtEpoch(address(maker), root), 1);
    }

    function testWrongMakerCannotUseApprovedRoot() public {
        PolicyMaker otherMaker = new PolicyMaker();
        offer.maker = address(otherMaker);
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(address(maker));
        ratifier.setRoot(address(maker), root, true);

        vm.expectRevert(IPolicySetterRatifier.RootNotApproved.selector);
        midnight.ratify(ratifier, offer, abi.encode(root, 0, new bytes32[](0)));
    }

    function testPinnedOfferHashVector() public view {
        assertEq(HashLib.hashOffer(offer), 0xba8fc5f602d151726b39ed9adf032c561fad2a48a1054d0f933bcebf766cbb91);
        assertEq(
            HashLib.hashNode(HashLib.hashOffer(offer), bytes32(uint256(1))),
            0xddaa6fa986426ab64033137a98a05327d246dd971526b85acb20b3e4e4d9ae17
        );
    }
}
