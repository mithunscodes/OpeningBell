// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { FullMath } from "v4-core/libraries/FullMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";

/// @notice Conversions between human prices (18 decimals) and Uniswap's sqrt prices, plus the two
///         liquidity formulas the vault needs. Both pool tokens are assumed to have 18 decimals.
library PriceMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;

    error PriceOutOfRange();
    error LiquidityOverflow();

    /// @notice sqrt(ratio) as a Q64.96 number, where `ratioWad` is "currency1 per currency0" with 18 decimals.
    function toSqrtPriceX96(uint256 ratioWad) internal pure returns (uint160) {
        // ratioWad * 2^192 / 1e18 must fit in 256 bits.
        if (ratioWad == 0 || ratioWad >= (uint256(1) << 64) * WAD) revert PriceOutOfRange();
        return uint160(sqrt(FullMath.mulDiv(ratioWad, 1 << 192, WAD)));
    }

    /// @notice "currency1 per currency0" with 18 decimals, from a Q64.96 sqrt price.
    function toRatioWad(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), WAD, Q96);
    }

    /// @notice 1 / ratio, both with 18 decimals.
    function invert(uint256 ratioWad) internal pure returns (uint256) {
        if (ratioWad == 0) revert PriceOutOfRange();
        return (WAD * WAD) / ratioWad;
    }

    /// @notice Largest liquidity that `amount0` and `amount1` can back in [sqrtA, sqrtB] at price sqrtP.
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint256 liquidity;
        if (sqrtP <= sqrtA) {
            liquidity = _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = _liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint256 l1 = _liquidityForAmount1(sqrtA, sqrtP, amount1);
            liquidity = l0 < l1 ? l0 : l1;
        } else {
            liquidity = _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
        // Liquidity deltas are signed 128-bit numbers in the pool manager.
        if (liquidity > uint128(type(int128).max)) revert LiquidityOverflow();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity);
    }

    /// @notice Token amounts held by `liquidity` in [sqrtA, sqrtB] at price sqrtP, rounded down.
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(sqrtA, sqrtB, Q96), sqrtB - sqrtA);
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint256) {
        return FullMath.mulDiv(amount1, Q96, sqrtB - sqrtA);
    }

    /// @notice Integer square root, rounded down (Babylonian method).
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        // Start from a power of two at or above the root, then iterate. Seven rounds are enough for 256 bits.
        uint256 y = x;
        z = 1;
        if (y >> 128 != 0) {
            y >>= 128;
            z <<= 64;
        }
        if (y >> 64 != 0) {
            y >>= 64;
            z <<= 32;
        }
        if (y >> 32 != 0) {
            y >>= 32;
            z <<= 16;
        }
        if (y >> 16 != 0) {
            y >>= 16;
            z <<= 8;
        }
        if (y >> 8 != 0) {
            y >>= 8;
            z <<= 4;
        }
        if (y >> 4 != 0) {
            y >>= 4;
            z <<= 2;
        }
        if (y >> 2 != 0) z <<= 1;
        unchecked {
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            uint256 other = x / z;
            if (other < z) z = other;
        }
    }
}
