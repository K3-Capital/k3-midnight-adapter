// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {BlueMidnightAdapter} from "./BlueMidnightAdapter.sol";

/// @title Blue Midnight adapter factory
/// @notice Permissionless CREATE2 deployment for immutable adapter instances.
/// @dev The salt is namespaced by the factory's constructor arguments. A salt
///      can therefore never accidentally deploy an adapter for a different
///      vault or protocol configuration at the same address.
contract BlueMidnightAdapterFactory {
    error AlreadyDeployed(address adapter);
    error InvalidSalt();

    event AdapterDeployed(
        address indexed adapter,
        bytes32 indexed salt,
        address indexed parentVault,
        address midnight,
        address morphoBlue,
        address ratifier
    );

    function deploy(bytes32 salt, address parentVault, address midnight, address morphoBlue, address ratifier)
        external
        returns (address adapter)
    {
        if (salt == bytes32(0)) revert InvalidSalt();
        adapter = predict(salt, parentVault, midnight, morphoBlue, ratifier);
        if (adapter.code.length != 0) revert AlreadyDeployed(adapter);
        adapter = address(new BlueMidnightAdapter{salt: salt}(parentVault, midnight, morphoBlue, ratifier));
        emit AdapterDeployed(adapter, salt, parentVault, midnight, morphoBlue, ratifier);
    }

    function predict(bytes32 salt, address parentVault, address midnight, address morphoBlue, address ratifier)
        public
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(BlueMidnightAdapter).creationCode, abi.encode(parentVault, midnight, morphoBlue, ratifier)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
