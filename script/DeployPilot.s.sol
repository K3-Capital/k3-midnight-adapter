// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {BlueMidnightAdapter} from "../src/BlueMidnightAdapter.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";
import {MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {MarketEconomicPolicy} from "../src/types/AdapterTypes.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";

/// @notice Deploys one adapter directly from explicit immutable configuration.
/// @dev Verification runs before the operator registers the adapter with Vault V2.
contract DeployPilot is Script {
    using MarketParamsLib for MarketParams;

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

        BlueMidnightAdapter deployed = BlueMidnightAdapter(adapter);
        _verifyDeployment(
            deployed,
            parentVault,
            blueMarket,
            midnight,
            morphoBlue,
            ratifier,
            pinnedMidnightMarket,
            policy,
            quoter,
            expectedCodeHash
        );
    }

    function verifyDeployment(
        BlueMidnightAdapter deployed,
        address parentVault,
        MarketParams memory blueMarket,
        address midnight,
        address morphoBlue,
        address ratifier,
        Market memory pinnedMidnightMarket,
        MarketEconomicPolicy memory policy,
        address quoter,
        bytes32 expectedCodeHash
    ) external view {
        _verifyDeployment(
            deployed,
            parentVault,
            blueMarket,
            midnight,
            morphoBlue,
            ratifier,
            pinnedMidnightMarket,
            policy,
            quoter,
            expectedCodeHash
        );
    }

    function _verifyDeployment(
        BlueMidnightAdapter deployed,
        address parentVault,
        MarketParams memory blueMarket,
        address midnight,
        address morphoBlue,
        address ratifier,
        Market memory pinnedMidnightMarket,
        MarketEconomicPolicy memory policy,
        address quoter,
        bytes32 expectedCodeHash
    ) internal view {
        require(deployed.parentVault() == parentVault, "parent vault mismatch");
        require(deployed.asset() == IVaultV2(parentVault).asset(), "asset mismatch");
        require(deployed.midnight() == midnight, "midnight mismatch");
        require(deployed.morphoBlue() == morphoBlue, "morpho mismatch");
        require(deployed.ratifier() == ratifier, "ratifier mismatch");
        require(deployed.approvedQuoter() == quoter, "quoter mismatch");
        _verifyBlueMarket(deployed, blueMarket);
        _verifyMidnightMarket(deployed, pinnedMidnightMarket);
        _verifyPolicy(deployed.marketEconomicPolicy(), policy);
        require(address(deployed).codehash == expectedCodeHash, "runtime code hash mismatch");
    }

    function _verifyBlueMarket(BlueMidnightAdapter deployed, MarketParams memory expected) internal view {
        (MarketParams memory actual, bytes32 id) = deployed.blueMarket();
        require(actual.loanToken == expected.loanToken, "blue loan token mismatch");
        require(actual.collateralToken == expected.collateralToken, "blue collateral token mismatch");
        require(actual.oracle == expected.oracle, "blue oracle mismatch");
        require(actual.irm == expected.irm, "blue irm mismatch");
        require(actual.lltv == expected.lltv, "blue lltv mismatch");
        require(id == Id.unwrap(expected.id()), "blue market id mismatch");
    }

    function _verifyMidnightMarket(BlueMidnightAdapter deployed, Market memory expected) internal view {
        Market memory actual = deployed.pinnedMidnightMarket();
        require(HashLib.hashMarket(actual) == HashLib.hashMarket(expected), "midnight market hash mismatch");
        require(IdLib.toId(actual) == IdLib.toId(expected), "midnight market id mismatch");
        require(actual.chainId == expected.chainId, "midnight chain mismatch");
        require(actual.midnight == expected.midnight, "midnight address mismatch");
        require(actual.loanToken == expected.loanToken, "midnight loan token mismatch");
        require(actual.maturity == expected.maturity, "midnight maturity mismatch");
        require(actual.rcfThreshold == expected.rcfThreshold, "midnight threshold mismatch");
        require(actual.enterGate == expected.enterGate, "midnight enter gate mismatch");
        require(actual.liquidatorGate == expected.liquidatorGate, "midnight liquidator gate mismatch");
        require(actual.collateralParams.length == expected.collateralParams.length, "collateral count mismatch");
        for (uint256 i; i < expected.collateralParams.length; ++i) {
            CollateralParams memory a = actual.collateralParams[i];
            CollateralParams memory e = expected.collateralParams[i];
            require(a.token == e.token && a.lltv == e.lltv, "collateral parameters mismatch");
            require(a.liquidationCursor == e.liquidationCursor && a.oracle == e.oracle, "collateral oracle mismatch");
        }
    }

    function _verifyPolicy(MarketEconomicPolicy memory actual, MarketEconomicPolicy memory expected) internal pure {
        require(actual.maxBuyTick == expected.maxBuyTick, "policy buy tick mismatch");
        require(actual.minSellTick == expected.minSellTick, "policy sell tick mismatch");
        require(actual.maxTenor == expected.maxTenor, "policy tenor mismatch");
        require(actual.maxExpiryHorizon == expected.maxExpiryHorizon, "policy expiry mismatch");
        require(
            actual.maxContinuousFeePerSecondWad == expected.maxContinuousFeePerSecondWad,
            "policy continuous fee mismatch"
        );
        require(actual.maxSettlementFeeWad == expected.maxSettlementFeeWad, "policy settlement fee mismatch");
        require(actual.configured == expected.configured, "policy configured mismatch");
    }
}
