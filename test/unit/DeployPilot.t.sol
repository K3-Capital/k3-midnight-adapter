// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployPilot} from "../../script/DeployPilot.s.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {MarketEconomicPolicy} from "../../src/types/AdapterTypes.sol";
import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";

contract DeployVerificationToken {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract DeployVerificationVault {
    address public immutable asset;
    address public immutable curator;

    constructor(address asset_) {
        asset = asset_;
        curator = msg.sender;
    }

    function isSentinel(address) external pure returns (bool) {
        return false;
    }
}

contract DeployVerificationRatifier {}

contract DeployVerificationMidnightAuth {
    function setIsAuthorized(address, bool, address onBehalf) external {
        require(onBehalf == msg.sender, "caller");
    }
}

contract DeployPilotVerificationTest is Test {
    DeployVerificationToken internal token;
    DeployVerificationVault internal vault;
    DeployVerificationRatifier internal ratifier;
    BlueMidnightAdapter internal adapter;
    MarketParams internal blueMarket;
    Market internal midnightMarket;
    MarketEconomicPolicy internal policy;
    address internal constant MIDNIGHT = address(0x1000);
    address internal constant MORPHO = address(0x200);
    address internal constant QUOTER = address(0x300);

    function setUp() public {
        token = new DeployVerificationToken();
        vm.etch(MIDNIGHT, type(DeployVerificationMidnightAuth).runtimeCode);
        vault = new DeployVerificationVault(address(token));
        ratifier = new DeployVerificationRatifier();
        blueMarket = MarketParams(address(token), address(0), address(0x400), address(0x500), 0);
        midnightMarket = Market({
            chainId: block.chainid,
            midnight: MIDNIGHT,
            loanToken: address(token),
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
        policy = MarketEconomicPolicy(100, 1, 20 days);
        adapter = new BlueMidnightAdapter(
            address(vault), blueMarket, MIDNIGHT, MORPHO, address(ratifier), midnightMarket, policy, QUOTER
        );
    }

    function testDeployPilotVerifiesEveryPinnedFieldAndRuntimeHash() public {
        DeployPilot pilot = new DeployPilot();
        pilot.verifyDeployment(
            adapter,
            address(vault),
            blueMarket,
            MIDNIGHT,
            MORPHO,
            address(ratifier),
            midnightMarket,
            policy,
            QUOTER,
            address(adapter).codehash
        );
    }

    function testDeployPilotRejectsWrongRuntimeHash() public {
        DeployPilot pilot = new DeployPilot();
        vm.expectRevert(bytes("runtime code hash mismatch"));
        pilot.verifyDeployment(
            adapter,
            address(vault),
            blueMarket,
            MIDNIGHT,
            MORPHO,
            address(ratifier),
            midnightMarket,
            policy,
            QUOTER,
            bytes32(uint256(1))
        );
    }

    function testDirectDeploymentRecordsReproducibleConstructorGas() public {
        uint256 beforeGas = gasleft();
        new BlueMidnightAdapter(
            address(vault), blueMarket, MIDNIGHT, MORPHO, address(ratifier), midnightMarket, policy, QUOTER
        );
        uint256 usedGas = beforeGas - gasleft();
        emit log_named_uint("direct constructor gas", usedGas);
        assertGt(usedGas, 0);
    }
}
