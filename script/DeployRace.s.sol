// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IRefPrice, MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { BellGuard } from "../src/venue/BellGuard.sol";
import { BellHook } from "../src/venue/BellHook.sol";
import { BellVault } from "../src/venue/BellVault.sol";
import { Arena } from "../src/venue/Arena.sol";
import { MockToken } from "../src/venue/MockToken.sol";
import { PriceMath } from "../src/venue/lib/PriceMath.sol";
import { Config } from "./Config.sol";
import { DeployBase, PoolKeyId } from "./Deploy.s.sol";

/// @notice "Beat the bell": a separate market and a separate pair of pools on Base Sepolia, so a bot
///         can race the live loop as often as we like without touching the demo.
/// @dev    Nothing new is deployed on Reactive Network: the conductor and the watchdog already handle
///         any market id the feed publishes, and the demo page only reads its own market id. On Base
///         this re-uses the live guard and both live hooks, with fresh tokens (so the pools are new),
///         two fresh vaults and a fresh arena that scores raids against the feed itself. That is the
///         fastest attacker there can be: it learns the new price from the very event that starts
///         the loop, on the same chain.
///
///         Run after DeployVenue on Base Sepolia. Writes deployments/race-84532.json.
contract DeployRace is DeployBase {
    bytes32 internal constant RACE_MARKET_ID = keccak256("NVDA/USD race");

    struct Race {
        MockToken stock;
        MockToken dollars;
        BellVault vault;
        BellVault twinVault;
        Arena arena;
        PoolKey key;
        PoolKey twinKey;
    }

    function run() external {
        require(block.chainid == Config.ORIGIN_CHAIN, "the race runs on the origin chain");
        string memory venueFile = _venueFile(block.chainid);
        MarketFeed feed = MarketFeed(_read("origin.json", ".feed"));
        BellGuard guard = BellGuard(payable(_read(venueFile, ".guard")));
        BellHook hook = BellHook(_read(venueFile, ".hook"));
        BellHook twinHook = BellHook(_read(venueFile, ".twinHook"));
        IPoolManager manager = IPoolManager(Config.poolManager(block.chainid));

        Race memory r;
        uint256 startBlock = block.number;

        vm.startBroadcast(_key());

        r.stock = new MockToken("Mock NVDA, race (testnet)", "rNVDA");
        r.dollars = new MockToken("Mock USD, race (testnet)", "rUSD");

        bool stockIs0 = address(r.stock) < address(r.dollars);
        (Currency c0, Currency c1) = stockIs0
            ? (Currency.wrap(address(r.stock)), Currency.wrap(address(r.dollars)))
            : (Currency.wrap(address(r.dollars)), Currency.wrap(address(r.stock)));
        r.key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(address(hook)));
        r.twinKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(address(twinHook)));

        uint160 startSqrt =
            PriceMath.toSqrtPriceX96(stockIs0 ? Config.START_PRICE : PriceMath.invert(Config.START_PRICE));
        manager.initialize(r.key, startSqrt);
        manager.initialize(r.twinKey, startSqrt);

        r.vault = new BellVault(manager, guard, RACE_MARKET_ID, r.key, address(r.stock));
        r.twinVault = new BellVault(manager, guard, RACE_MARKET_ID, r.twinKey, address(r.stock));
        hook.registerPool(r.key, BellHook.PoolConfig(RACE_MARKET_ID, address(r.vault), false, 0, 0, 0));
        twinHook.registerPool(
            r.twinKey, BellHook.PoolConfig(RACE_MARKET_ID, address(r.twinVault), true, Config.OPEN_FEE, 0, 0)
        );

        // Both targets refill and catch up after every raid, so each attempt starts from a full pool
        // and is scored on its own.
        r.arena = new Arena(manager, IRefPrice(address(feed)), RACE_MARKET_ID, r.stock, r.dollars);
        r.arena.setTarget(0, r.key, r.vault, true, Config.VAULT_STOCK, Config.VAULT_DOLLARS);
        r.arena.setTarget(1, r.twinKey, r.twinVault, true, Config.VAULT_STOCK, Config.VAULT_DOLLARS);
        r.stock.setMinter(address(r.arena), true);
        r.dollars.setMinter(address(r.arena), true);
        r.vault.setKeeper(address(r.arena));
        r.twinVault.setKeeper(address(r.arena));

        r.stock.mint(address(r.vault), Config.VAULT_STOCK);
        r.dollars.mint(address(r.vault), Config.VAULT_DOLLARS);
        r.stock.mint(address(r.twinVault), Config.VAULT_STOCK);
        r.dollars.mint(address(r.twinVault), Config.VAULT_DOLLARS);
        r.vault.reposition(Config.START_PRICE, Config.OPEN_RANGE_BPS);
        r.twinVault.reposition(Config.START_PRICE, Config.OPEN_RANGE_BPS);

        // The protected race vault gets the fast path, exactly like the demo's protected vault.
        guard.setListener(RACE_MARKET_ID, address(r.vault));

        // First state for the race market. Until it lands, the protected race pool refuses to trade.
        feed.publish(RACE_MARKET_ID, MarketTypes.OPEN, Config.START_PRICE, uint64(block.timestamp));

        vm.stopBroadcast();

        string memory json = "race";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", startBlock);
        vm.serializeBytes32(json, "marketId", RACE_MARKET_ID);
        vm.serializeAddress(json, "stock", address(r.stock));
        vm.serializeAddress(json, "dollars", address(r.dollars));
        vm.serializeAddress(json, "vault", address(r.vault));
        vm.serializeAddress(json, "twinVault", address(r.twinVault));
        vm.serializeBytes32(json, "poolId", PoolKeyId.unwrap(r.key));
        vm.serializeBytes32(json, "twinPoolId", PoolKeyId.unwrap(r.twinKey));
        vm.writeJson(
            vm.serializeAddress(json, "arena", address(r.arena)),
            string.concat(_dir(), "race-", vm.toString(block.chainid), ".json")
        );

        console2.log("race vault     ", address(r.vault));
        console2.log("race twin vault", address(r.twinVault));
        console2.log("race arena     ", address(r.arena));
    }
}
