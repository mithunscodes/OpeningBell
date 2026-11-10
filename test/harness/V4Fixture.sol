// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
import { MockToken } from "../../src/venue/MockToken.sol";

/// @notice Puts the real Uniswap v4 PoolManager into the test EVM.
/// @dev    The fixture is the runtime bytecode read from Base Sepolia (`cast code`). It is placed at
///         the same address it has there, because the contract remembers its own address to refuse
///         delegate calls. Tests therefore run against the exact code the demo runs against, without
///         having to compile the pool manager (which is pinned to another compiler version).
abstract contract V4Fixture is Test {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    function _v4SetUp() internal {
        bytes memory code = vm.parseBytes(vm.trim(vm.readFile("test/fixtures/PoolManager.base-sepolia.hex")));
        vm.etch(address(POOL_MANAGER), code);
        vm.label(address(POOL_MANAGER), "PoolManager");
    }
}

/// @notice An ordinary trader or liquidity provider, for tests. Pays with tokens it holds.
contract Trader is IUnlockCallback {
    IPoolManager internal immutable POOL_MANAGER;

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta)
    {
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(true, key, abi.encode(SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96)))
        );
        return abi.decode(result, (BalanceDelta));
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(false, key, abi.encode(ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, bytes32(0))))
        );
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "not pool manager");
        (bool isSwap, PoolKey memory key, bytes memory params) = abi.decode(data, (bool, PoolKey, bytes));

        BalanceDelta delta;
        if (isSwap) {
            delta = POOL_MANAGER.swap(key, abi.decode(params, (SwapParams)), "");
        } else {
            (delta,) = POOL_MANAGER.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        }

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount > 0) {
            POOL_MANAGER.take(currency, address(this), uint128(amount));
        } else if (amount < 0) {
            POOL_MANAGER.sync(currency);
            MockToken(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), uint128(-amount));
            POOL_MANAGER.settle();
        }
    }
}
