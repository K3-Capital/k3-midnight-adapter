// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

/// @dev Canonical namespaces for Vault V2 allocation/risk identifiers.
library RiskIdLib {
    function adapter(address adapterAddress) internal pure returns (bytes32) {
        return keccak256(abi.encode("this", adapterAddress));
    }

    function blue(bytes32 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode("morpho-blue", marketId));
    }

    function midnight(address protocol) internal pure returns (bytes32) {
        return keccak256(abi.encode("midnight", protocol));
    }

    function midnightMarket(bytes32 marketHash) internal pure returns (bytes32) {
        return keccak256(abi.encode("midnight-market", marketHash));
    }
}
