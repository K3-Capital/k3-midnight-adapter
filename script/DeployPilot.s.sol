// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BlueMidnightAdapterFactory} from "../src/BlueMidnightAdapterFactory.sol";

/// @notice Deploys one pilot adapter from explicit environment configuration.
/// @dev Addresses and salt are inputs, never committed deployment state.
contract DeployPilot is Script {
    function run() external returns (address adapter) {
        BlueMidnightAdapterFactory factory = BlueMidnightAdapterFactory(vm.envAddress("ADAPTER_FACTORY"));
        bytes32 salt = vm.envBytes32("ADAPTER_SALT");
        address parentVault = vm.envAddress("PARENT_VAULT");
        address midnight = vm.envAddress("MIDNIGHT");
        address morphoBlue = vm.envAddress("MORPHO_BLUE");
        address ratifier = vm.envAddress("RATIFIER");

        vm.startBroadcast();
        adapter = factory.deploy(salt, parentVault, midnight, morphoBlue, ratifier);
        vm.stopBroadcast();
    }
}
