// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { MarketTypes } from "../common/MarketTypes.sol";
import { BellGuard } from "./BellGuard.sol";

/// @title BellHook
/// @notice Uniswap v4 hook that makes a pool follow the trading hours of a reference market.
///         Before every swap it asks the chain's `BellGuard` what the market is doing:
///
///         - HALTED, or nothing known yet: the swap is refused.
///         - OPEN or CLOSED: the swap goes through at the fee the conductor chose for that status.
///
///         Liquidity can only be added by the pool's vault, so the vault can move the pool to a new
///         reference price for free while it is the only liquidity provider.
/// @dev    A pool can also be registered as `passive`: it ignores the guard and always charges
///         `baseFee`. That is the control group: a pool with no idea what time it is on Wall Street.
contract BellHook is IHooks {
    struct PoolConfig {
        bytes32 marketId;
        address vault;
        bool passive;
        /// @dev Fee of a passive pool, in hundredths of a basis point.
        uint24 baseFee;
        /// @dev If the market says OPEN but the guard has not heard anything for this many seconds,
        ///      `staleFee` is charged instead. Zero disables the check.
        uint32 maxStale;
        uint24 staleFee;
    }

    event PoolRegistered(PoolId indexed poolId, bytes32 indexed marketId, address vault, bool passive);

    error NotPoolManager();
    error NotOwner();
    error HookNotImplemented();
    error PoolNotRegistered();
    error OnlyVault();
    error MarketHalted();
    error NoMarketData();
    error NotDynamicFee();
    error WrongHook();

    IPoolManager public immutable POOL_MANAGER;
    BellGuard public immutable GUARD;

    address public owner;
    mapping(PoolId => PoolConfig) public pools;

    constructor(IPoolManager poolManager_, BellGuard guard_, address owner_) {
        POOL_MANAGER = poolManager_;
        GUARD = guard_;
        owner = owner_;

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------------------------------

    function registerPool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!LPFeeLibrary.isDynamicFee(key.fee)) revert NotDynamicFee();
        LPFeeLibrary.validate(config.baseFee);
        LPFeeLibrary.validate(config.staleFee);

        PoolId id = key.toId();
        pools[id] = config;
        emit PoolRegistered(id, config.marketId, config.vault, config.passive);
    }

    function transferOwnership(address to) external onlyOwner {
        owner = to;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice What a swap in this pool would be charged right now, and whether it would be allowed.
    function quote(PoolId id) public view returns (bool tradable, uint24 feePips) {
        PoolConfig memory c = pools[id];
        if (c.vault == address(0)) return (false, 0);
        if (c.passive) return (true, c.baseFee);

        (uint8 status,, uint24 guardFee,, uint64 seq, uint64 appliedAt) = GUARD.current(c.marketId);
        if (seq == 0 || status == MarketTypes.HALTED) return (false, 0);

        if (c.maxStale != 0 && status == MarketTypes.OPEN && block.timestamp - appliedAt > c.maxStale) {
            return (true, c.staleFee);
        }
        return (true, guardFee);
    }

    // ---------------------------------------------------------------------------------------------
    // Hooks in use
    // ---------------------------------------------------------------------------------------------

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig memory c = pools[id];
        if (c.vault == address(0)) revert PoolNotRegistered();

        // The vault only swaps to move an empty pool to a new price. Nothing is traded, so no fee applies.
        if (sender == c.vault) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        if (c.passive) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                c.baseFee | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        (uint8 status,, uint24 guardFee,, uint64 seq, uint64 appliedAt) = GUARD.current(c.marketId);
        if (seq == 0) revert NoMarketData();
        if (status == MarketTypes.HALTED) revert MarketHalted();

        uint24 fee = guardFee;
        if (c.maxStale != 0 && status == MarketTypes.OPEN && block.timestamp - appliedAt > c.maxStale) {
            fee = c.staleFee;
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        address vault = pools[key.toId()].vault;
        if (vault == address(0)) revert PoolNotRegistered();
        if (sender != vault) revert OnlyVault();
        return IHooks.beforeAddLiquidity.selector;
    }

    // ---------------------------------------------------------------------------------------------
    // Hooks not in use. The pool manager never calls them because the address has no flag for them.
    // ---------------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
