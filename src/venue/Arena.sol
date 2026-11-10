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
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { IRefPrice } from "../common/MarketTypes.sol";
import { BellHook } from "./BellHook.sol";
import { BellVault } from "./BellVault.sol";
import { MockToken } from "./MockToken.sol";
import { PriceMath } from "./lib/PriceMath.sol";

/// @title Arena
/// @notice Lets anyone play the villain with one transaction and no set-up. `raid()` does what an
///         arbitrage bot does to a pool whose price is out of date: it trades against the pool until
///         the pool's price matches the real one, and keeps the difference.
/// @dev    The raider trades with play money that this contract mints for the occasion, so a player
///         needs no tokens and no approvals. What is real is the pool: every dollar a raid makes is
///         a dollar the pool's liquidity provider lost. The contract keeps score per player and per pool.
contract Arena is IUnlockCallback {
    using StateLibrary for IPoolManager;

    struct Target {
        PoolKey key;
        BellVault vault;
        /// @dev After a raid, tell the vault to catch up with the market. This plays the part of a
        ///      liquidity manager who arrives after the raider.
        bool catchUpAfter;
    }

    /// @param pnl Profit of the raider in dollars (18 decimals), valued at the reference price.
    event Raid(
        address indexed player,
        uint256 indexed targetId,
        bool soldStock,
        uint256 amountIn,
        uint256 amountOut,
        int256 pnl,
        uint256 poolPriceBefore,
        uint256 refPrice
    );

    /// @notice The pool refused to trade. `reason` is the raw revert data from the pool manager.
    event RaidBlocked(address indexed player, uint256 indexed targetId, bytes reason);

    /// @notice The pool's price was already where it should be: nothing to take.
    event RaidPointless(address indexed player, uint256 indexed targetId, uint256 poolPrice, uint256 refPrice);

    event TargetSet(uint256 indexed targetId, PoolId poolId, address vault, bool catchUpAfter);

    error NotOwner();
    error NotPoolManager();
    error NotSelf();
    error UnknownTarget();

    /// @dev More than any pool in the demo can absorb. The price limit stops the swap long before this.
    int256 internal constant MAX_IN = 1e30;

    IPoolManager public immutable POOL_MANAGER;
    IRefPrice public immutable PRICE_SOURCE;
    bytes32 public immutable MARKET_ID;
    MockToken public immutable STOCK;
    MockToken public immutable DOLLARS;

    address public owner;
    mapping(uint256 => Target) internal _targets;

    /// @notice Total profit each player has made, in dollars.
    mapping(address => int256) public loot;
    /// @notice Total profit raiders have taken out of each pool, in dollars.
    mapping(uint256 => int256) public taken;
    mapping(uint256 => uint256) public raids;
    mapping(uint256 => uint256) public blocked;

    constructor(
        IPoolManager poolManager_,
        IRefPrice priceSource_,
        bytes32 marketId_,
        MockToken stock_,
        MockToken dollars_
    ) {
        POOL_MANAGER = poolManager_;
        PRICE_SOURCE = priceSource_;
        MARKET_ID = marketId_;
        STOCK = stock_;
        DOLLARS = dollars_;
        owner = msg.sender;
    }

    function setTarget(uint256 targetId, PoolKey calldata key, BellVault vault, bool catchUpAfter) external {
        if (msg.sender != owner) revert NotOwner();
        _targets[targetId] = Target(key, vault, catchUpAfter);
        emit TargetSet(targetId, key.toId(), address(vault), catchUpAfter);
    }

    function target(uint256 targetId) external view returns (Target memory) {
        return _targets[targetId];
    }

    // ---------------------------------------------------------------------------------------------
    // Raiding
    // ---------------------------------------------------------------------------------------------

    /// @notice Arbitrage one pool against the reference price, as far as it pays after fees.
    /// @return pnl The raider's profit in dollars (18 decimals). Zero if blocked or pointless.
    function raid(uint256 targetId) external returns (int256 pnl) {
        Target memory t = _targets[targetId];
        if (address(t.vault) == address(0)) revert UnknownTarget();

        uint256 refPrice = PRICE_SOURCE.priceOf(MARKET_ID);

        try this.attempt(targetId, refPrice) returns (
            bool traded, bool soldStock, uint256 amountIn, uint256 amountOut, uint256 poolPriceBefore
        ) {
            if (!traded) {
                emit RaidPointless(msg.sender, targetId, poolPriceBefore, refPrice);
            } else {
                // forge-lint: disable-start(unsafe-typecast)
                pnl = soldStock
                    ? int256(amountOut) - int256(amountIn * refPrice / 1e18)
                    : int256(amountOut * refPrice / 1e18) - int256(amountIn);
                // forge-lint: disable-end(unsafe-typecast)

                loot[msg.sender] += pnl;
                taken[targetId] += pnl;
                ++raids[targetId];
                emit Raid(msg.sender, targetId, soldStock, amountIn, amountOut, pnl, poolPriceBefore, refPrice);
            }
        } catch (bytes memory reason) {
            ++blocked[targetId];
            emit RaidBlocked(msg.sender, targetId, reason);
        }

        if (t.catchUpAfter) t.vault.catchUp();
    }

    /// @notice What `raid()` would find right now: the pool's price, the reference price, and whether
    ///         the pool would trade at all.
    function scout(uint256 targetId)
        external
        view
        returns (uint256 poolPrice, uint256 refPrice, bool tradable, uint24 feePips)
    {
        Target memory t = _targets[targetId];
        if (address(t.vault) == address(0)) revert UnknownTarget();
        poolPrice = _stockPrice(t.key, _sqrtPrice(t.key));
        refPrice = PRICE_SOURCE.priceOf(MARKET_ID);
        (tradable, feePips) = BellHook(address(t.key.hooks)).quote(t.key.toId());
    }

    /// @dev Separate external call so that a refusal by the pool can be caught and reported.
    function attempt(uint256 targetId, uint256 refPrice)
        external
        returns (bool traded, bool soldStock, uint256 amountIn, uint256 amountOut, uint256 poolPriceBefore)
    {
        if (msg.sender != address(this)) revert NotSelf();
        return abi.decode(POOL_MANAGER.unlock(abi.encode(targetId, refPrice)), (bool, bool, uint256, uint256, uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint256 targetId, uint256 refPrice) = abi.decode(data, (uint256, uint256));

        PoolKey memory k = _targets[targetId].key;
        bool stockIs0 = Currency.unwrap(k.currency0) == address(STOCK);
        uint160 sqrtBefore = _sqrtPrice(k);
        uint256 poolPrice = _stockPrice(k, sqrtBefore);

        (, uint24 feePips) = BellHook(address(k.hooks)).quote(k.toId());

        // A trade pays only while the pool's price, after the fee, is still better than the real price.
        // Selling stock into an overpriced pool pays down to ref / (1 - fee); buying from an
        // underpriced pool pays up to ref * (1 - fee).
        bool sellStock = poolPrice > refPrice;
        uint256 stopPrice = sellStock ? refPrice * 1e6 / (1e6 - feePips) : refPrice * (1e6 - feePips) / 1e6;
        if (refPrice == 0 || (sellStock ? poolPrice <= stopPrice : poolPrice >= stopPrice)) {
            return abi.encode(false, sellStock, uint256(0), uint256(0), poolPrice);
        }

        uint160 limit = PriceMath.toSqrtPriceX96(stockIs0 ? stopPrice : PriceMath.invert(stopPrice));
        bool zeroForOne = limit < sqrtBefore;
        if (limit == sqrtBefore) return abi.encode(false, sellStock, uint256(0), uint256(0), poolPrice);

        BalanceDelta delta = POOL_MANAGER.swap(
            k, SwapParams({ zeroForOne: zeroForOne, amountSpecified: -MAX_IN, sqrtPriceLimitX96: limit }), ""
        );

        // forge-lint: disable-start(unsafe-typecast)
        uint256 amountIn = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 amountOut = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        // forge-lint: disable-end(unsafe-typecast)

        // Pay with freshly minted play money, and collect the proceeds.
        if (amountIn != 0) {
            Currency currencyIn = zeroForOne ? k.currency0 : k.currency1;
            POOL_MANAGER.sync(currencyIn);
            MockToken(Currency.unwrap(currencyIn)).mint(address(POOL_MANAGER), amountIn);
            POOL_MANAGER.settle();
        }
        if (amountOut != 0) {
            POOL_MANAGER.take(zeroForOne ? k.currency1 : k.currency0, address(this), amountOut);
        }

        return abi.encode(amountIn != 0 || amountOut != 0, sellStock, amountIn, amountOut, poolPrice);
    }

    function _sqrtPrice(PoolKey memory k) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(k.toId());
    }

    function _stockPrice(PoolKey memory k, uint160 sqrtPriceX96) internal view returns (uint256) {
        uint256 ratio = PriceMath.toRatioWad(sqrtPriceX96);
        return Currency.unwrap(k.currency0) == address(STOCK) ? ratio : PriceMath.invert(ratio);
    }
}
