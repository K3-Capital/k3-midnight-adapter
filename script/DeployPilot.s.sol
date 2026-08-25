// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BlueMidnightAdapter} from "../src/BlueMidnightAdapter.sol";
import {Market} from "midnight/interfaces/IMidnight.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketEconomicPolicy} from "../src/types/AdapterTypes.sol";

/// @notice Deploys one adapter directly from explicit immutable configuration.
/// @dev The script verifies every constructor value and runtime code hash before broadcast.
contract DeployPilot is Script {
    function run() external returns (address adapter) {
        address parentVault = vm.envAddress("PARENT_VAULT");
        MarketParams memory blueMarket = abi.decode(vm.envBytes("BLUE_MARKET"), (MarketParams));
        address midnight = vm.envAddress("MIDNIGHT");
        address morphoBlue = vm.envAddress("MORPHO_BLUE");
        address ratifier = vm.envAddress("RATIFIER");
        Market memory pinnedMidnightMarket = abi.decode(vm.envBytes("MIDNIGHT_MARKET"), (Market));
        MarketEconomicPolicy memory policy = abi.decode(vm.envBytes("ECONOMIC_POLICY"), (MarketEconomicPolicy));
        address quoter = vm.envAddress("APPROVED_QUOTER");
        bytes32 expectedCodeHash = vm.envBytes32("EXPECTED_RUNTIME_CODE_HASH");

        vm.startBroadcast();
        adapter = address(
            new BlueMidnightAdapter(
                parentVault, blueMarket, midnight, morphoBlue, ratifier, pinnedMidnightMarket, policy, quoter
            )
        );
        vm.stopBroadcast();

        require(BlueMidnightAdapter(adapter).parentVault() == parentVault, "parent vault mismatch");
        require(BlueMidnightAdapter(adapter).midnight() == midnight, "midnight mismatch");
        require(BlueMidnightAdapter(adapter).morphoBlue() == morphoBlue, "morpho mismatch");
        require(BlueMidnightAdapter(adapter).ratifier() == ratifier, "ratifier mismatch");
        require(BlueMidnightAdapter(adapter).approvedQuoter() == quoter, "quoter mismatch");
        require(adapter.codehash == expectedCodeHash, "runtime code hash mismatch");
    }
}
