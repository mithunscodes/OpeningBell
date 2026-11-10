// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { BellReactive } from "../src/reactive/BellReactive.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";

/// @notice Addresses and settings shared by the deployment scripts.
library Config {
    uint256 internal constant LASNA = 5318007;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    /// @dev The market feed lives here.
    uint256 internal constant ORIGIN_CHAIN = BASE_SEPOLIA;

    bytes32 internal constant MARKET_ID = keccak256("NVDA/USD");

    uint256 internal constant START_PRICE = 140e18;
    uint256 internal constant VAULT_STOCK = 1_000e18;
    uint256 internal constant VAULT_DOLLARS = 140_000e18;

    int24 internal constant TICK_SPACING = 10;

    uint24 internal constant OPEN_FEE = 500; // 0.05%
    uint24 internal constant OPEN_RANGE_BPS = 200; // +-2%
    uint24 internal constant CLOSED_FEE = 30_000; // 3%
    uint24 internal constant CLOSED_RANGE_BPS = 1_500; // +-15%

    /// @dev Gas the conductor asks for on each venue callback. Re-positioning the vault uses about 400k.
    uint64 internal constant CALLBACK_GAS = 1_000_000;
    /// @dev Price-only moves smaller than this are not sent to venues.
    uint16 internal constant MIN_MOVE_BPS = 5;

    /// @dev Public demo limits: one action every 15 seconds, 100 a day.
    uint32 internal constant STAGE_COOLDOWN = 15;
    uint32 internal constant STAGE_DAILY_CAP = 100;

    function callbackProxy(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
        if (chainId == UNICHAIN_SEPOLIA) return 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
        revert("Config: no callback proxy for this chain");
    }

    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == BASE_SEPOLIA) return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        if (chainId == UNICHAIN_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        revert("Config: no pool manager for this chain");
    }

    function policy() internal pure returns (BellReactive.Policy[3] memory p) {
        p[MarketTypes.CLOSED] = BellReactive.Policy(CLOSED_FEE, CLOSED_RANGE_BPS);
        p[MarketTypes.OPEN] = BellReactive.Policy(OPEN_FEE, OPEN_RANGE_BPS);
        p[MarketTypes.HALTED] = BellReactive.Policy(0, 0);
    }
}
