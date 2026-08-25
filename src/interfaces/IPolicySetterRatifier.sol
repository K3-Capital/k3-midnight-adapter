// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";

interface IPolicySetterRatifier {
    error UnauthorizedCaller();
    error MalformedRatifierData();
    error InvalidProof();
    error RootNotApproved();
    error InvalidPolicyProvider();
    error PolicyEpochUnset();
    error OfferRejected();

    event RootApprovalUpdated(address indexed maker, bytes32 indexed root, uint64 epoch, bool approved);
    event SetIsRootRatified(
        address indexed caller, address indexed maker, bytes32 indexed root, bool newIsRootRatified
    );

    function MIDNIGHT() external view returns (address);
    function approvedAtEpoch(address maker, bytes32 root) external view returns (uint64);
    function setRoot(address maker, bytes32 root, bool approved) external;
    function setIsRootRatified(address maker, bytes32 root, bool approved) external;
    function isRatified(Offer calldata offer, bytes calldata ratifierData, address taker)
        external
        view
        returns (bytes32);
}
