// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IRefPrice } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { DemoStage } from "../src/origin/DemoStage.sol";
import { BellReactive } from "../src/reactive/BellReactive.sol";
import { BellGuard } from "../src/venue/BellGuard.sol";
import { BellHook } from "../src/venue/BellHook.sol";
import { BellVault } from "../src/venue/BellVault.sol";
import { Arena } from "../src/venue/Arena.sol";
import { MockToken } from "../src/venue/MockToken.sol";
import { PriceMath } from "../src/venue/lib/PriceMath.sol";
import { Config } from "./Config.sol";

/// @notice Shared plumbing: the deployer key and the JSON files that carry addresses between steps.
/// @dev    Deployment order: DeployOrigin (Base Sepolia), DeployConductor (Lasna), DeployVenue (once
///         on Base Sepolia, once on Unichain Sepolia), WireVenues (Lasna). See docs/DEPLOY.md.
abstract contract DeployBase is Script {
    function _key() internal view returns (uint256) {
        return vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _dir() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/", vm.envOr("DEPLOYMENTS_DIR", string("deployments")), "/");
    }

    function _read(string memory file, string memory key) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(string.concat(_dir(), file)), key);
    }

    function _venueFile(uint256 chainId) internal pure returns (string memory) {
        return string.concat("venue-", vm.toString(chainId), ".json");
    }
}

/// @notice Step 1, on the origin chain: the market feed and the public demo trigger.
contract DeployOrigin is DeployBase {
    function run() external {
        require(block.chainid == Config.ORIGIN_CHAIN, "run this on the origin chain");
        uint256 key = _key();

        vm.startBroadcast(key);
        MarketFeed feed = new MarketFeed();
        DemoStage stage = new DemoStage(feed, Config.MARKET_ID, Config.STAGE_COOLDOWN, Config.STAGE_DAILY_CAP);
        feed.setPublisher(address(stage), true);
        feed.setPublisher(vm.addr(key), true);
        vm.stopBroadcast();

        string memory json = "origin";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.serializeAddress(json, "feed", address(feed));
        vm.writeJson(vm.serializeAddress(json, "stage", address(stage)), string.concat(_dir(), "origin.json"));

        console2.log("MarketFeed", address(feed));
        console2.log("DemoStage ", address(stage));
    }
}

/// @notice Step 2, on Reactive Network: the conductor, funded from the deployer.
contract DeployConductor is DeployBase {
    function run() external {
        require(block.chainid == Config.LASNA, "run this on Reactive Lasna");
        address feed = _read("origin.json", ".feed");
        uint256 funding = vm.envOr("CONDUCTOR_FUNDING", uint256(2 ether));

        vm.startBroadcast(_key());
        BellReactive conductor =
            new BellReactive{ value: funding }(Config.ORIGIN_CHAIN, feed, BellReactive.AckMode.Always);
        vm.stopBroadcast();

        string memory json = "reactive";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", block.number);
        vm.writeJson(vm.serializeAddress(json, "conductor", address(conductor)), string.concat(_dir(), "reactive.json"));

        console2.log("BellReactive", address(conductor));
    }
}

/// @notice Step 3, on each venue chain: guard, tokens, two pools (protected and twin), vaults, arena.
contract DeployVenue is DeployBase {
    struct Venue {
        BellGuard guard;
        MockToken stock;
        MockToken dollars;
        BellHook hook;
        BellHook twinHook;
        BellVault vault;
        BellVault twinVault;
        Arena arena;
        PoolKey key;
        PoolKey twinKey;
    }

    function run() external {
        uint256 key = _key();
        address deployer = vm.addr(key);
        address conductor = _read("reactive.json", ".conductor");
        IPoolManager manager = IPoolManager(Config.poolManager(block.chainid));
        uint256 guardFunding = vm.envOr("GUARD_FUNDING", uint256(0.002 ether));

        Venue memory v;
        uint256 startBlock = block.number;

        vm.startBroadcast(key);

        v.guard =
            new BellGuard{ value: guardFunding }(IPayable(payable(Config.callbackProxy(block.chainid))), conductor);
        v.stock = new MockToken("Mock NVDA (testnet demo)", "mNVDA");
        v.dollars = new MockToken("Mock USD (testnet demo)", "mUSD");

        // Two instances of the same hook, so the protected pool and its twin are identical in every
        // other respect. Their addresses must carry the hook's permissions in the low bits.
        bytes memory args = abi.encode(manager, v.guard, deployer);
        (bytes32 salt, address predicted) = _mine(args, 0);
        v.hook = new BellHook{ salt: salt }(manager, v.guard, deployer);
        require(address(v.hook) == predicted, "hook address mismatch");
        (salt, predicted) = _mine(args, uint256(salt) + 1);
        v.twinHook = new BellHook{ salt: salt }(manager, v.guard, deployer);
        require(address(v.twinHook) == predicted, "twin hook address mismatch");

        bool stockIs0 = address(v.stock) < address(v.dollars);
        (Currency c0, Currency c1) = stockIs0
            ? (Currency.wrap(address(v.stock)), Currency.wrap(address(v.dollars)))
            : (Currency.wrap(address(v.dollars)), Currency.wrap(address(v.stock)));
        v.key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(address(v.hook)));
        v.twinKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, Config.TICK_SPACING, IHooks(address(v.twinHook)));

        uint160 startSqrt =
            PriceMath.toSqrtPriceX96(stockIs0 ? Config.START_PRICE : PriceMath.invert(Config.START_PRICE));
        manager.initialize(v.key, startSqrt);
        manager.initialize(v.twinKey, startSqrt);

        v.vault = new BellVault(manager, v.guard, Config.MARKET_ID, v.key, address(v.stock));
        v.twinVault = new BellVault(manager, v.guard, Config.MARKET_ID, v.twinKey, address(v.stock));

        v.hook.registerPool(v.key, BellHook.PoolConfig(Config.MARKET_ID, address(v.vault), false, 0, 0, 0));
        v.twinHook
            .registerPool(
                v.twinKey, BellHook.PoolConfig(Config.MARKET_ID, address(v.twinVault), true, Config.OPEN_FEE, 0, 0)
            );

        // On the origin chain the arena scores raids against the feed itself. Elsewhere the guard is
        // the only on-chain source of the reference price.
        IRefPrice priceSource = block.chainid == Config.ORIGIN_CHAIN
            ? IRefPrice(_read("origin.json", ".feed"))
            : IRefPrice(address(v.guard));
        v.arena = new Arena(manager, priceSource, Config.MARKET_ID, v.stock, v.dollars);
        v.arena.setTarget(0, v.key, v.vault, false, 0, 0);
        v.arena.setTarget(1, v.twinKey, v.twinVault, true, Config.VAULT_STOCK, Config.VAULT_DOLLARS);
        v.stock.setMinter(address(v.arena), true);
        v.dollars.setMinter(address(v.arena), true);
        v.twinVault.setKeeper(address(v.arena));

        // Same money in both vaults, positioned at the starting price.
        v.stock.mint(address(v.vault), Config.VAULT_STOCK);
        v.dollars.mint(address(v.vault), Config.VAULT_DOLLARS);
        v.stock.mint(address(v.twinVault), Config.VAULT_STOCK);
        v.dollars.mint(address(v.twinVault), Config.VAULT_DOLLARS);
        v.vault.reposition(Config.START_PRICE, Config.OPEN_RANGE_BPS);
        v.twinVault.reposition(Config.START_PRICE, Config.OPEN_RANGE_BPS);

        // From here on the protected vault is driven by Reactive Network callbacks.
        v.guard.setListener(Config.MARKET_ID, address(v.vault));

        vm.stopBroadcast();

        _write(v, startBlock);
    }

    function _mine(bytes memory args, uint256 from) internal view returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(BellHook).creationCode, args));
        uint160 wanted = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

        for (uint256 i = from; i != from + 1_000_000; ++i) {
            predicted = vm.computeCreate2Address(bytes32(i), initCodeHash, CREATE2_FACTORY);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == wanted && predicted.code.length == 0) {
                return (bytes32(i), predicted);
            }
        }
        revert("no hook salt found");
    }

    function _write(Venue memory v, uint256 startBlock) internal {
        string memory json = "venue";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "block", startBlock);
        vm.serializeAddress(json, "poolManager", Config.poolManager(block.chainid));
        vm.serializeAddress(json, "callbackProxy", Config.callbackProxy(block.chainid));
        vm.serializeAddress(json, "guard", address(v.guard));
        vm.serializeAddress(json, "stock", address(v.stock));
        vm.serializeAddress(json, "dollars", address(v.dollars));
        vm.serializeAddress(json, "hook", address(v.hook));
        vm.serializeAddress(json, "twinHook", address(v.twinHook));
        vm.serializeAddress(json, "vault", address(v.vault));
        vm.serializeAddress(json, "twinVault", address(v.twinVault));
        vm.serializeBytes32(json, "poolId", PoolKeyId.unwrap(v.key));
        vm.serializeBytes32(json, "twinPoolId", PoolKeyId.unwrap(v.twinKey));
        vm.writeJson(
            vm.serializeAddress(json, "arena", address(v.arena)), string.concat(_dir(), _venueFile(block.chainid))
        );

        console2.log("BellGuard ", address(v.guard));
        console2.log("BellHook  ", address(v.hook));
        console2.log("BellVault ", address(v.vault));
        console2.log("Arena     ", address(v.arena));
    }
}

/// @notice Step 4, on Reactive Network: tell the conductor about every venue that has been deployed.
contract WireVenues is DeployBase {
    function run() external {
        require(block.chainid == Config.LASNA, "run this on Reactive Lasna");
        BellReactive conductor = BellReactive(payable(_read("reactive.json", ".conductor")));

        uint256[2] memory chains = [Config.BASE_SEPOLIA, Config.UNICHAIN_SEPOLIA];

        vm.startBroadcast(_key());
        for (uint256 i = 0; i != chains.length; ++i) {
            string memory file = _venueFile(chains[i]);
            if (!vm.exists(string.concat(_dir(), file))) continue;

            address guard = _read(file, ".guard");
            (bool known,) = conductor.venueIdOf(chains[i], guard);
            if (known) continue;

            uint256 venueId =
                conductor.addVenue(chains[i], guard, Config.CALLBACK_GAS, Config.MIN_MOVE_BPS, Config.policy());
            console2.log("venue", venueId, chains[i], guard);
        }
        vm.stopBroadcast();
    }
}

library PoolKeyId {
    function unwrap(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}
