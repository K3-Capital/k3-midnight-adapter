// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Market, CollateralParams} from "midnight/interfaces/IMidnight.sol";

library AdapterTestMarket {
    function make(address midnight, address loanToken) internal view returns (Market memory) {
        return Market({
            chainId: block.chainid,
            midnight: midnight,
            loanToken: loanToken,
            collateralParams: new CollateralParams[](0),
            maturity: block.timestamp + 30 days,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }
}
