// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

/// @notice Scalar accounting arithmetic shared by the adapter and its accounting tests.
library AccountingLib {
    error NarrowingOverflow();
    error DivisionByZero();

    /// @dev Explicit checked narrowing; callers rely on reverting rather than wrapping.
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) revert NarrowingOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    /// @dev Round down so partial repayment/sale reductions cannot overstate NAV.
    function proportionalDown(uint256 value, uint256 units, uint256 totalUnits) internal pure returns (uint256) {
        if (totalUnits == 0) revert DivisionByZero();
        return value * units / totalUnits;
    }
}
