// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PriceMath } from "../src/venue/lib/PriceMath.sol";

/// @notice The price maths on its own, including the edges the pools never reach.
contract PriceMathTest is Test {
    uint256 internal constant Q96 = 1 << 96;

    // External wrappers, so that reverts inside the library can be expected.
    function toSqrt(uint256 ratioWad) external pure returns (uint160) {
        return PriceMath.toSqrtPriceX96(ratioWad);
    }

    function invert(uint256 ratioWad) external pure returns (uint256) {
        return PriceMath.invert(ratioWad);
    }

    function liquidity(uint160 p, uint160 a, uint160 b, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return PriceMath.liquidityForAmounts(p, a, b, amount0, amount1);
    }

    function _isFloorRoot(uint256 x, uint256 z) internal pure returns (bool) {
        // z is at most 2^128 - 1, so z * z fits, and so does (z + 1)^2 unless z is the largest root.
        return z * z <= x && (z == type(uint128).max || (z + 1) * (z + 1) > x);
    }

    // ------------------------------------------------------------------------------------------
    // Square root
    // ------------------------------------------------------------------------------------------

    function test_SquareRootsAreRoundedDown() public pure {
        assertEq(PriceMath.sqrt(0), 0);
        assertEq(PriceMath.sqrt(1), 1);
        assertEq(PriceMath.sqrt(2), 1);
        assertEq(PriceMath.sqrt(3), 1);
        assertEq(PriceMath.sqrt(4), 2);
        assertEq(PriceMath.sqrt(15), 3);
        assertEq(PriceMath.sqrt(16), 4);
        assertEq(PriceMath.sqrt(1e36), 1e18);
        assertEq(PriceMath.sqrt(1e36 - 1), 1e18 - 1);
        assertEq(PriceMath.sqrt(type(uint256).max), type(uint128).max);
    }

    /// @dev Around every power of two, which is where the starting guess changes.
    function test_SquareRootsAreRoundedDownAtEveryPowerOfTwo() public pure {
        for (uint256 k = 1; k != 256; ++k) {
            uint256 x = uint256(1) << k;
            assertTrue(_isFloorRoot(x - 1, PriceMath.sqrt(x - 1)), "just below");
            assertTrue(_isFloorRoot(x, PriceMath.sqrt(x)), "at");
            assertTrue(_isFloorRoot(x + 1, PriceMath.sqrt(x + 1)), "just above");
            assertTrue(_isFloorRoot(x + (x >> 1), PriceMath.sqrt(x + (x >> 1))), "half way");
        }
        for (uint256 j = 1; j != 128; ++j) {
            uint256 r = (uint256(1) << j) + 1;
            assertEq(PriceMath.sqrt(r * r), r, "a square");
            assertEq(PriceMath.sqrt(r * r - 1), r - 1, "one below a square");
        }
    }

    function testFuzz_TheSquareRootIsAlwaysRoundedDown(uint256 x, uint8 shift) public pure {
        x >>= shift; // all sizes of number, not just huge ones
        assertTrue(_isFloorRoot(x, PriceMath.sqrt(x)));
    }

    // ------------------------------------------------------------------------------------------
    // Prices
    // ------------------------------------------------------------------------------------------

    function test_PricesConvertOnlyInsideTheirRange() public {
        uint256 top = (uint256(1) << 64) * 1e18;
        assertGt(this.toSqrt(1), 0, "the smallest price, 1e-18");
        assertGt(this.toSqrt(top - 1), this.toSqrt(top / 2), "the largest price");
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        this.toSqrt(0);
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        this.toSqrt(top);
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        this.toSqrt(top * 2);

        assertEq(this.toSqrt(1e18), Q96, "a price of 1 is 2^96");
        assertEq(this.toSqrt(4e18), 2 * Q96);
        assertEq(PriceMath.toRatioWad(uint160(Q96)), 1e18);
        assertEq(PriceMath.toRatioWad(uint160(2 * Q96)), 4e18);
    }

    function testFuzz_APriceSurvivesTheRoundTrip(uint256 ratioWad) public view {
        ratioWad = bound(ratioWad, 1e12, (uint256(1) << 64) * 1e18 - 1);
        uint256 back = PriceMath.toRatioWad(this.toSqrt(ratioWad));
        assertLe(back, ratioWad, "rounded down");
        assertApproxEqRel(back, ratioWad, 1e9, "to within a billionth");
    }

    function test_InvertingAPrice() public {
        assertEq(this.invert(1e18), 1e18);
        assertEq(this.invert(2e18), 0.5e18);
        assertEq(this.invert(3e18), 333_333_333_333_333_333);
        assertEq(this.invert(1), 1e36);
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        this.invert(0);
    }

    // ------------------------------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------------------------------

    function test_BelowTheBandItIsAllToken0AndAboveItAllToken1() public view {
        uint160 a = TickMath.getSqrtPriceAtTick(-600);
        uint160 b = TickMath.getSqrtPriceAtTick(600);
        uint160[2] memory below = [TickMath.getSqrtPriceAtTick(-1200), a];
        uint160[2] memory above = [TickMath.getSqrtPriceAtTick(1200), b];

        for (uint256 i = 0; i != 2; ++i) {
            // At or below the lower edge, only token0 counts.
            uint128 l = this.liquidity(below[i], a, b, 1e18, 0);
            assertEq(this.liquidity(below[i], a, b, 1e18, 5e18), l, "token1 is not needed");
            (uint256 x0, uint256 x1) = PriceMath.amountsForLiquidity(below[i], a, b, l);
            assertEq(x1, 0);
            assertLe(x0, 1e18);
            assertApproxEqAbs(x0, 1e18, 2);

            // At or above the upper edge, only token1 counts.
            l = this.liquidity(above[i], a, b, 0, 1e18);
            assertEq(this.liquidity(above[i], a, b, 5e18, 1e18), l, "token0 is not needed");
            (x0, x1) = PriceMath.amountsForLiquidity(above[i], a, b, l);
            assertEq(x0, 0);
            assertLe(x1, 1e18);
            assertApproxEqAbs(x1, 1e18, 2);
        }
    }

    function test_InsideTheBandTheScarcerTokenSetsTheLiquidity() public view {
        uint160 a = TickMath.getSqrtPriceAtTick(-600);
        uint160 b = TickMath.getSqrtPriceAtTick(600);
        uint160 p = uint160(Q96); // a price of 1, in the middle

        uint128 short0 = this.liquidity(p, a, b, 1e18, 2e18);
        assertEq(this.liquidity(p, a, b, 1e18, 9e18), short0, "with token0 scarce, more token1 adds nothing");
        uint128 short1 = this.liquidity(p, a, b, 2e18, 1e18);
        assertEq(this.liquidity(p, a, b, 9e18, 1e18), short1, "with token1 scarce, more token0 adds nothing");
        assertApproxEqRel(short0, short1, 1e6, "the band is symmetric around the price");

        (uint256 x0, uint256 x1) = PriceMath.amountsForLiquidity(p, a, b, short0);
        assertLe(x0, 1e18);
        assertApproxEqAbs(x0, 1e18, 2, "all of the scarce token is used");
        assertApproxEqRel(x1, 1e18, 1e6, "and as much of the other");
    }

    function test_LiquidityStopsExactlyAtTheLargestSigned128BitNumber() public {
        // With the band from 2^96 to 2^97, the liquidity above it is exactly amount1, and below it twice amount0.
        uint160 a = uint160(Q96);
        uint160 b = uint160(2 * Q96);
        uint256 max = uint256(uint128(type(int128).max));
        assertEq(this.liquidity(a, a, b, 1e18, 0), 2e18);
        assertEq(this.liquidity(b, a, b, 0, 1e18), 1e18);
        assertEq(this.liquidity(b, a, b, 0, max), max);
        vm.expectRevert(PriceMath.LiquidityOverflow.selector);
        this.liquidity(b, a, b, 0, max + 1);
    }
}
