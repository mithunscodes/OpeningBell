// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { BellGuard, IMarketListener } from "./BellGuard.sol";
import { PriceMath } from "./lib/PriceMath.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title BellVault
/// @notice Holds the liquidity of one stock/dollar pool and re-positions it whenever the reference
///         market changes. One call does three things inside a single pool-manager unlock:
///
///         1. take all liquidity out of the pool,
///         2. move the (now empty) pool to the new reference price, which costs nothing,
///         3. put the liquidity back in a band around that price.
///
///         So when a stock reopens 10% lower, the pool reopens 10% lower too, and nobody gets to
///         buy the vault's dollars with overpriced stock on the way down.
/// @dev    The vault is the only liquidity provider in its pool (`BellHook` enforces that), which
///         is what makes step 2 free. A band of zero width means "stay out of the pool".
contract BellVault is IMarketListener, IUnlockCallback {
    using StateLibrary for IPoolManager;

    event Repositioned(
        uint256 price, uint24 halfRangeBps, int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96
    );
    event KeeperSet(address keeper);

    error NotAuthorized();
    error NotPoolManager();
    error WrongMarket();
    error BadRange();

    IPoolManager public immutable POOL_MANAGER;
    BellGuard public immutable GUARD;
    bytes32 public immutable MARKET_ID;
    /// @dev True if the stock token sorts below the dollar token, so the pool's own price is "dollars per share".
    bool public immutable STOCK_IS_CURRENCY0;

    PoolKey public key;
    address public owner;
    /// @dev An address besides the owner that may call `catchUp()`. Used by the control-group pool.
    address public keeper;

    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;

    constructor(IPoolManager poolManager_, BellGuard guard_, bytes32 marketId_, PoolKey memory key_, address stock_) {
        POOL_MANAGER = poolManager_;
        GUARD = guard_;
        MARKET_ID = marketId_;
        key = key_;
        STOCK_IS_CURRENCY0 = Currency.unwrap(key_.currency0) == stock_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Drivers
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IMarketListener
    /// @dev Called by the guard inside the Reactive Network callback: this is the fast path.
    function onMarketState(bytes32 marketId, uint8, uint256 price, uint24, uint24 halfRangeBps) external {
        if (msg.sender != address(GUARD)) revert NotAuthorized();
        if (marketId != MARKET_ID) revert WrongMarket();
        _reposition(price, halfRangeBps);
    }

    /// @notice Re-positions to whatever the guard currently says. This is the slow path: somebody has
    ///         to send a transaction, the way a keeper bot would.
    function catchUp() external {
        if (msg.sender != owner && msg.sender != keeper) revert NotAuthorized();
        (, uint256 price,, uint24 halfRangeBps, uint64 seq,) = GUARD.current(MARKET_ID);
        if (seq == 0) return;
        _reposition(price, halfRangeBps);
    }

    /// @notice Manual positioning, used once at set-up before the first market update arrives.
    function reposition(uint256 price, uint24 halfRangeBps) external onlyOwner {
        _reposition(price, halfRangeBps);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function transferOwnership(address to) external onlyOwner {
        owner = to;
    }

    /// @notice Takes idle tokens out of the vault. Liquidity in the pool is not touched.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20Like(token).transfer(to, amount), "transfer failed");
    }

    // ---------------------------------------------------------------------------------------------
    // Re-positioning
    // ---------------------------------------------------------------------------------------------

    function _reposition(uint256 price, uint24 halfRangeBps) internal {
        if (halfRangeBps >= 10_000) revert BadRange();
        POOL_MANAGER.unlock(abi.encode(price, halfRangeBps));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint256 price, uint24 halfRangeBps) = abi.decode(data, (uint256, uint24));

        PoolKey memory k = key;
        int256 net0;
        int256 net1;

        // 1. Everything out.
        if (liquidity != 0) {
            (BalanceDelta removed,) = POOL_MANAGER.modifyLiquidity(
                k,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            net0 += removed.amount0();
            net1 += removed.amount1();
            liquidity = 0;
        }

        uint160 sqrtPriceX96;
        if (halfRangeBps != 0) {
            // 2. Move the empty pool to the reference price.
            uint160 target = _sqrtPriceFor(price);
            (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(k.toId());
            if (sqrtPriceX96 != target) {
                // With no liquidity in range the swap consumes nothing and stops at the limit price.
                // If somebody else's liquidity were there, it could spend at most the 1 wei specified.
                BalanceDelta moved = POOL_MANAGER.swap(
                    k,
                    SwapParams({ zeroForOne: target < sqrtPriceX96, amountSpecified: -1, sqrtPriceLimitX96: target }),
                    ""
                );
                net0 += moved.amount0();
                net1 += moved.amount1();
                (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(k.toId());
            }

            // 3. Everything back in, in a band around the reference price.
            (int24 lower, int24 upper) = _band(price, halfRangeBps, k.tickSpacing);
            uint128 newLiquidity = PriceMath.liquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(lower),
                TickMath.getSqrtPriceAtTick(upper),
                _available(k.currency0, net0),
                _available(k.currency1, net1)
            );

            if (newLiquidity != 0) {
                (BalanceDelta added,) = POOL_MANAGER.modifyLiquidity(
                    k,
                    ModifyLiquidityParams({
                        tickLower: lower,
                        tickUpper: upper,
                        liquidityDelta: int256(uint256(newLiquidity)),
                        salt: bytes32(0)
                    }),
                    ""
                );
                net0 += added.amount0();
                net1 += added.amount1();
                tickLower = lower;
                tickUpper = upper;
                liquidity = newLiquidity;
            }
        }

        _settle(k.currency0, net0);
        _settle(k.currency1, net1);

        emit Repositioned(price, halfRangeBps, tickLower, tickUpper, liquidity, sqrtPriceX96);
        return "";
    }

    /// @dev What the vault can put into the pool: its own balance plus what the pool manager owes it.
    function _available(Currency currency, int256 owed) internal view returns (uint256) {
        int256 total = int256(IERC20Like(Currency.unwrap(currency)).balanceOf(address(this))) + owed;
        return total > 0 ? uint256(total) : 0;
    }

    /// @dev Positive: the pool manager owes the vault. Negative: the vault owes the pool manager.
    function _settle(Currency currency, int256 net) internal {
        if (net > 0) {
            POOL_MANAGER.take(currency, address(this), uint256(net));
        } else if (net < 0) {
            POOL_MANAGER.sync(currency);
            require(IERC20Like(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), uint256(-net)), "pay failed");
            POOL_MANAGER.settle();
        }
    }

    /// @dev Pool price (currency1 per currency0) for a stock price in dollars.
    function _sqrtPriceFor(uint256 price) internal view returns (uint160) {
        return PriceMath.toSqrtPriceX96(STOCK_IS_CURRENCY0 ? price : PriceMath.invert(price));
    }

    /// @dev Ticks of the band [price * (1 - half), price * (1 + half)], widened to the tick spacing.
    function _band(uint256 price, uint24 halfRangeBps, int24 spacing) internal view returns (int24 lower, int24 upper) {
        uint160 a = _sqrtPriceFor(price * (10_000 - halfRangeBps) / 10_000);
        uint160 b = _sqrtPriceFor(price * (10_000 + halfRangeBps) / 10_000);
        if (a > b) (a, b) = (b, a);

        lower = _floor(TickMath.getTickAtSqrtPrice(a), spacing);
        upper = _floor(TickMath.getTickAtSqrtPrice(b), spacing) + spacing;

        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
        return compressed * spacing;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Everything the vault owns: idle balances plus what its liquidity is worth in tokens.
    function holdings() public view returns (uint256 stock, uint256 dollars) {
        PoolKey memory k = key;
        uint256 amount0 = IERC20Like(Currency.unwrap(k.currency0)).balanceOf(address(this));
        uint256 amount1 = IERC20Like(Currency.unwrap(k.currency1)).balanceOf(address(this));

        if (liquidity != 0) {
            (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(k.toId());
            (uint256 in0, uint256 in1) = PriceMath.amountsForLiquidity(
                sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
            );
            amount0 += in0;
            amount1 += in1;
        }

        return STOCK_IS_CURRENCY0 ? (amount0, amount1) : (amount1, amount0);
    }

    /// @notice Value of everything the vault owns, in dollars, at the given stock price. Uncollected
    ///         swap fees are not counted.
    function valueAt(uint256 price) external view returns (uint256) {
        (uint256 stock, uint256 dollars) = holdings();
        return dollars + stock * price / 1e18;
    }

    /// @notice The pool's own price for the stock, in dollars with 18 decimals.
    function poolPrice() external view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint256 ratio = PriceMath.toRatioWad(sqrtPriceX96);
        return STOCK_IS_CURRENCY0 ? ratio : PriceMath.invert(ratio);
    }
}
