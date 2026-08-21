// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {IPolicySetterRatifier} from "./interfaces/IPolicySetterRatifier.sol";
import {IOfferPolicy} from "./interfaces/IOfferPolicy.sol";
import {Offer} from "midnight/interfaces/IMidnight.sol";
import {CALLBACK_SUCCESS} from "midnight/libraries/ConstantsLib.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";

/// @notice Maker-controlled, epoch-bound offer-tree ratifier for the immutable Midnight instance.
contract PolicySetterRatifier is IPolicySetterRatifier {
    address public immutable MIDNIGHT;
    mapping(address maker => mapping(bytes32 root => uint64 epoch)) public approvedAtEpoch;

    constructor(address midnight) {
        MIDNIGHT = midnight;
    }

    /// @dev Only the maker may relay root approval. In particular, quoters are never
    /// checked through Midnight's broad maker authorization mechanism.
    function setRoot(address maker, bytes32 root, bool approved) external {
        _setRoot(maker, root, approved);
    }

    function _setRoot(address maker, bytes32 root, bool approved) internal {
        if (maker != msg.sender) revert UnauthorizedCaller();
        uint64 epoch;
        if (approved) {
            epoch = _policyEpoch(maker);
            if (epoch == 0) revert PolicyEpochUnset();
        }
        approvedAtEpoch[maker][root] = epoch;
        emit RootApprovalUpdated(maker, root, epoch, approved);
    }

    /// @dev Compatibility spelling for upstream callers; it retains maker-only semantics.
    function setIsRootRatified(address maker, bytes32 root, bool approved) external {
        _setRoot(maker, root, approved);
    }

    function isRatified(Offer calldata offer, bytes calldata ratifierData, address) external view returns (bytes32) {
        if (msg.sender != MIDNIGHT) revert UnauthorizedCaller();
        if (ratifierData.length < 96) revert MalformedRatifierData();
        (bytes32 root, uint256 leafIndex, bytes32[] memory proof) =
            abi.decode(ratifierData, (bytes32, uint256, bytes32[]));
        if (!HashLib.isLeaf(root, HashLib.hashOffer(offer), leafIndex, proof)) revert InvalidProof();

        uint64 epoch = _policyEpoch(offer.maker);
        if (epoch == 0 || approvedAtEpoch[offer.maker][root] != epoch) revert RootNotApproved();
        if (offer.maker.code.length == 0) revert InvalidPolicyProvider();
        if (!IOfferPolicy(offer.maker).acceptsOffer(offer)) revert OfferRejected();
        return CALLBACK_SUCCESS;
    }

    function _policyEpoch(address maker) internal view returns (uint64 epoch) {
        if (maker.code.length == 0) revert InvalidPolicyProvider();
        try IOfferPolicy(maker).policyEpoch() returns (uint64 currentEpoch) {
            epoch = currentEpoch;
        } catch {
            revert InvalidPolicyProvider();
        }
    }
}
