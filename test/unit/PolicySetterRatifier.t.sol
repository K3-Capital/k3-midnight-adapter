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
}
