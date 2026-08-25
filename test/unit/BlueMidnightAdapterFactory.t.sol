// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BlueMidnightAdapterFactory} from "../../src/BlueMidnightAdapterFactory.sol";
import {BlueMidnightAdapter} from "../../src/BlueMidnightAdapter.sol";
import {ExitToken, ExitVault, ExitMorpho} from "./BlueMidnightAdapterExit.t.sol";
import {AdapterTestMarket} from "../utils/AdapterTestMarket.sol";

contract BlueMidnightAdapterFactoryTest is Test {
    BlueMidnightAdapterFactory factory;
    ExitToken token;
    ExitVault vault;
    ExitMorpho morpho;

    function setUp() public {
        factory = new BlueMidnightAdapterFactory();
        token = new ExitToken();
        vault = new ExitVault(address(token));
        morpho = new ExitMorpho(address(token));
    }

    function testPredictMatchesCreate2Deployment() public {
        bytes32 salt = keccak256("pilot-usdc");
        address predicted = factory.predict(
            salt,
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );

        address deployed = factory.deploy(
            salt,
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );

        assertEq(deployed, predicted);
        assertEq(BlueMidnightAdapter(deployed).factory(), address(factory));
        assertEq(BlueMidnightAdapter(deployed).parentVault(), address(vault));
        assertEq(BlueMidnightAdapter(deployed).asset(), address(token));
    }

    function testSameSaltSupportsDistinctConfigurations() public {
        bytes32 salt = keccak256("same-human-readable-salt");
        address first = factory.deploy(
            salt,
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );
        address second = factory.deploy(
            salt,
            address(vault),
            address(6),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(6), address(token))
        );

        assertTrue(first != second);
        assertEq(BlueMidnightAdapter(second).midnight(), address(6));
    }

    function testZeroSaltRejected() public {
        vm.expectRevert(BlueMidnightAdapterFactory.InvalidSalt.selector);
        factory.deploy(
            bytes32(0),
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );
    }

    function testDuplicateDeploymentRejected() public {
        bytes32 salt = keccak256("duplicate");
        factory.deploy(
            salt,
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );

        vm.expectRevert();
        factory.deploy(
            salt,
            address(vault),
            address(4),
            address(morpho),
            address(5),
            AdapterTestMarket.make(address(4), address(token))
        );
    }
}
