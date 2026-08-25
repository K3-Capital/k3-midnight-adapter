// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BlueMidnightAdapterFactory} from "../src/BlueMidnightAdapterFactory.sol";

/// @notice Deploys the stateless factory. No private configuration is embedded.
contract DeployFactory is Script {
    function run() external returns (BlueMidnightAdapterFactory factory) {
        vm.startBroadcast();
        factory = new BlueMidnightAdapterFactory();
        vm.stopBroadcast();
    }
}
