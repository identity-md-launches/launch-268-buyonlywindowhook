// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Explicit rehearsal assumptions; the supplied workflow contains no numeric manifest price.
/// The manifest contributor must reconcile these values with the final launch configuration.
library LaunchParameters {
    uint160 internal constant SQRT_PRICE_X96 = 79_228_162_514_264_337_593_543_950_336_000;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 138120;
    int256 internal constant LIQUIDITY = 100_000 ether;
}
