// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { OmniTest } from "./harness/OmniTest.sol";
import { V4Fixture, Trader } from "./harness/V4Fixture.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { BellReactive } from "../src/reactive/BellReactive.sol";
import { BellGuard } from "../src/venue/BellGuard.sol";
import { BellHook } from "../src/venue/BellHook.sol";
import { BellVault } from "../src/venue/BellVault.sol";
import { Arena } from "../src/venue/Arena.sol";
import { MockToken } from "../src/venue/MockToken.sol";
import { PriceMath } from "../src/venue/lib/PriceMath.sol";

/// @notice Everything on one venue: a protected pool, an unprotected twin, and the raid arena,
///         driven end to end through the simulated Reactive Network.
abstract contract BellPoolBase is OmniTest, V4Fixture {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    uint256 internal constant PROTECTED = 0;
    uint256 internal constant TWIN = 1;

    uint24 internal constant OPEN_FEE = 500; // 0.05%
    uint24 internal constant CLOSED_FEE = 30_000; // 3%
    uint24 internal constant OPEN_RANGE = 200; // +-2%
    uint24 internal constant CLOSED_RANGE = 1_500; // +-15%
    int24 internal constant TICK_SPACING = 10;

    uint256 internal constant START_PRICE = 140e18;
    uint256 internal constant START_STOCK = 1_000e18;
    uint256 internal constant START_DOLLARS = 140_000e18;

    bytes32 internal constant SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 internal constant RAID_SIG = keccak256("Raid(address,uint256,bool,uint256,uint256,int256,uint256,uint256)");
    bytes32 internal constant RAID_BLOCKED_SIG = keccak256("RaidBlocked(address,uint256,bytes)");
    bytes32 internal constant RAID_POINTLESS_SIG = keccak256("RaidPointless(address,uint256,uint256,uint256)");
    bytes32 internal constant LISTENER_FAILED_SIG = keccak256("ListenerFailed(bytes32,address,bytes)");

    address internal publisher = makeAddr("publisher");
    address internal player = makeAddr("player");

    MarketFeed internal feed;
    BellReactive internal conductor;
    BellGuard internal guard;
    BellHook internal hook;
    MockToken internal stock;
    MockToken internal dollars;
    BellVault internal vault;
    BellVault internal twinVault;
    Arena internal arena;
    Trader internal trader;
    PoolKey internal poolKey;
    PoolKey internal twinKey;

    /// @dev Overridden so the whole suite runs with the stock token on either side of the pool.
    function _stockIsCurrency0() internal pure virtual returns (bool);

    function setUp() public virtual {
        _omniSetUp();
        _v4SetUp();

        // Origin chain and Reactive Network.
        feed = new MarketFeed();
        feed.setPublisher(publisher, true);
        _place(address(feed), BASE_SEPOLIA);

        conductor = new BellReactive(BASE_SEPOLIA, address(feed), BellReactive.AckMode.Always);
        _place(address(conductor), LASNA);

        // Venue.
        guard = new BellGuard(IPayable(payable(address(_proxy(BASE_SEPOLIA)))), address(conductor));
        _place(address(guard), BASE_SEPOLIA);

        MockToken a = new MockToken("A", "A");
        MockToken b = new MockToken("B", "B");
        (stock, dollars) = (address(a) < address(b)) == _stockIsCurrency0() ? (a, b) : (b, a);

        // The hook's address has to carry its permissions in the low bits: beforeAddLiquidity | beforeSwap.
        address hookAddress = address(uint160(0xBE11 << 144) | uint160(0x0880));
        deployCodeTo("BellHook.sol:BellHook", abi.encode(POOL_MANAGER, guard, address(this)), hookAddress);
        hook = BellHook(hookAddress);

        (Currency c0, Currency c1) = address(stock) < address(dollars)
            ? (Currency.wrap(address(stock)), Currency.wrap(address(dollars)))
            : (Currency.wrap(address(dollars)), Currency.wrap(address(stock)));

        // Two pools that differ only in tick spacing, so they get different ids.
        poolKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(hookAddress));
        twinKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 1, IHooks(hookAddress));

        uint160 startSqrt = _sqrt(START_PRICE);
        POOL_MANAGER.initialize(poolKey, startSqrt);
        POOL_MANAGER.initialize(twinKey, startSqrt);

        vault = new BellVault(POOL_MANAGER, guard, NVDA, poolKey, address(stock));
        twinVault = new BellVault(POOL_MANAGER, guard, NVDA, twinKey, address(stock));

        hook.registerPool(poolKey, BellHook.PoolConfig(NVDA, address(vault), false, 0, 0, 0));
        hook.registerPool(twinKey, BellHook.PoolConfig(NVDA, address(twinVault), true, OPEN_FEE, 0, 0));

        arena = new Arena(POOL_MANAGER, feed, NVDA, stock, dollars);
        arena.setTarget(PROTECTED, poolKey, vault, false);
        arena.setTarget(TWIN, twinKey, twinVault, true);
        stock.setMinter(address(arena), true);
        dollars.setMinter(address(arena), true);
        twinVault.setKeeper(address(arena));

        // Same money in both vaults.
        stock.mint(address(vault), START_STOCK);
        dollars.mint(address(vault), START_DOLLARS);
        stock.mint(address(twinVault), START_STOCK);
        dollars.mint(address(twinVault), START_DOLLARS);

        // Only the protected vault hears from the Reactive Network.
        guard.setListener(NVDA, address(vault));
        conductor.addVenue(BASE_SEPOLIA, address(guard), 1_000_000, 0, _policy());

        trader = new Trader(POOL_MANAGER);
        stock.mint(address(trader), 1_000_000e18);
        dollars.mint(address(trader), 1_000_000_000e18);

        _pump();

        // Opening bell: both pools start in step with the market.
        _publish(MarketTypes.OPEN, START_PRICE);
        twinVault.catchUp();
        _pump();
    }

    function _policy() internal pure returns (BellReactive.Policy[3] memory p) {
        p[MarketTypes.CLOSED] = BellReactive.Policy(CLOSED_FEE, CLOSED_RANGE);
        p[MarketTypes.OPEN] = BellReactive.Policy(OPEN_FEE, OPEN_RANGE);
        p[MarketTypes.HALTED] = BellReactive.Policy(0, 0);
    }

    function _publish(uint8 status, uint256 price) internal returns (uint64 seq) {
        vm.prank(publisher);
        seq = feed.publish(NVDA, status, price, uint64(block.timestamp));
        _pump();
    }

    function _raid(uint256 targetId) internal returns (int256 pnl) {
        vm.prank(player);
        pnl = arena.raid(targetId);
        _pump();
    }

    function _sqrt(uint256 price) internal pure returns (uint160) {
        return PriceMath.toSqrtPriceX96(_stockIsCurrency0() ? price : PriceMath.invert(price));
    }

    function _hodlValue(uint256 price) internal pure returns (uint256) {
        return START_DOLLARS + START_STOCK * price / 1e18;
    }

    /// @dev The fee the pool manager actually charged on the most recent swap.
    function _lastSwapFee() internal view returns (uint24 fee) {
        Vm.Log memory log = _last(address(POOL_MANAGER), SWAP_SIG);
        (,,,,, fee) = abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
    }

    // ---------------------------------------------------------------------------------------------
    // The market opens
    // ---------------------------------------------------------------------------------------------

    function test_OpeningBellPutsLiquidityAroundTheReferencePrice() public view {
        assertApproxEqRel(vault.poolPrice(), START_PRICE, 1e12, "pool price");
        assertGt(vault.liquidity(), 0, "liquidity is in");

        // The band is +-2%, widened to the tick grid.
        uint256 lower = PriceMath.toRatioWad(TickMath.getSqrtPriceAtTick(vault.tickLower()));
        uint256 upper = PriceMath.toRatioWad(TickMath.getSqrtPriceAtTick(vault.tickUpper()));
        if (!_stockIsCurrency0()) (lower, upper) = (PriceMath.invert(upper), PriceMath.invert(lower));
        assertApproxEqRel(lower, START_PRICE * 98 / 100, 0.002e18, "lower edge");
        assertApproxEqRel(upper, START_PRICE * 102 / 100, 0.002e18, "upper edge");

        // Nothing was lost by going in.
        assertApproxEqRel(vault.valueAt(START_PRICE), _hodlValue(START_PRICE), 1e9);
        assertEq(_count(address(guard), LISTENER_FAILED_SIG), 0);
    }

    function test_OpenMarketChargesTheOpenFee() public {
        (bool tradable, uint24 fee) = hook.quote(poolKey.toId());
        assertTrue(tradable);
        assertEq(fee, OPEN_FEE);

        trader.swap(poolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        assertEq(_lastSwapFee(), OPEN_FEE);
    }

    function test_RaidingAPoolThatIsInStepIsPointless() public {
        assertEq(_raid(PROTECTED), 0);
        assertEq(_raid(TWIN), 0);
        assertEq(_count(address(arena), RAID_POINTLESS_SIG), 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Halt
    // ---------------------------------------------------------------------------------------------

    function test_HaltStopsTradingAndPullsLiquidity() public {
        _publish(MarketTypes.HALTED, START_PRICE);

        (bool tradable,) = hook.quote(poolKey.toId());
        assertFalse(tradable);
        assertEq(vault.liquidity(), 0, "liquidity is out");
        assertApproxEqRel(vault.valueAt(START_PRICE), _hodlValue(START_PRICE), 1e9, "nothing lost on the way out");

        vm.expectRevert();
        trader.swap(poolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_RaidDuringAHaltIsBlocked() public {
        _publish(MarketTypes.HALTED, START_PRICE);
        // The news is bad: the stock will reopen 10% lower. The feed already knows.
        vm.prank(publisher);
        feed.publish(NVDA, MarketTypes.HALTED, 126e18, uint64(block.timestamp));
        // The raider acts before the Reactive Network has delivered that second update.

        vm.prank(player);
        int256 pnl = arena.raid(PROTECTED);

        assertEq(pnl, 0);
        assertEq(arena.blocked(PROTECTED), 1);
        _pump();
        assertEq(_count(address(arena), RAID_BLOCKED_SIG), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Reopening at a new price
    // ---------------------------------------------------------------------------------------------

    function test_ReopeningLowerMovesTheProtectedPoolForFree() public {
        _publish(MarketTypes.HALTED, START_PRICE);
        _publish(MarketTypes.OPEN, 126e18);

        assertApproxEqRel(vault.poolPrice(), 126e18, 1e12, "pool reopened at the new price");
        assertGt(vault.liquidity(), 0);
        // The vault still owns exactly what it owned before. Only the price of the stock changed.
        assertApproxEqRel(vault.valueAt(126e18), _hodlValue(126e18), 1e9, "no value leaked");

        assertEq(_raid(PROTECTED), 0, "nothing to take");
    }

    function test_ReopeningLowerGetsTheTwinRaided() public {
        _publish(MarketTypes.HALTED, START_PRICE);
        _publish(MarketTypes.OPEN, 126e18);

        // The twin never heard about any of it: still quoting 140.
        assertApproxEqRel(twinVault.poolPrice(), START_PRICE, 1e12);
        uint256 before = twinVault.valueAt(126e18);

        int256 pnl = _raid(TWIN);

        assertGt(pnl, 0, "the raider made money");
        // The twin's band was 137.2 to 142.8. The raider sold it stock all the way down the band, at
        // about 138.6 on average, until the twin's 140,000 dollars were gone. That stock is worth 126.
        // 140,000 * (1 - 126 / 138.6) is about 12,700 dollars.
        assertApproxEqRel(uint256(pnl), 12_700e18, 0.02e18, "about 12,700 dollars");

        // Every dollar the raider made came out of the twin (which kept the swap fee).
        uint256 lost = before - twinVault.valueAt(126e18);
        assertApproxEqRel(lost, uint256(pnl), 0.01e18, "raider's gain is the twin's loss");

        assertEq(arena.loot(player), pnl);
        assertEq(arena.taken(TWIN), pnl);
        assertEq(arena.taken(PROTECTED), 0);

        // Afterwards the twin's manager catches up, too late.
        assertApproxEqRel(twinVault.poolPrice(), 126e18, 1e12);
        assertEq(_raid(TWIN), 0);
    }

    function test_ReopeningHigherWorksTheSameWay() public {
        _publish(MarketTypes.HALTED, START_PRICE);
        _publish(MarketTypes.OPEN, 161e18); // +15%

        assertApproxEqRel(vault.poolPrice(), 161e18, 1e12);
        assertApproxEqRel(vault.valueAt(161e18), _hodlValue(161e18), 1e9);
        assertEq(_raid(PROTECTED), 0);

        int256 pnl = _raid(TWIN);
        // The raider bought the twin's 1,000 shares up the band at about 141.4 on average while they
        // were worth 161: 1,000 * (161 - 141.4) is about 19,600 dollars.
        assertApproxEqRel(uint256(pnl), 19_600e18, 0.03e18, "about 19,600 dollars");
        assertApproxEqRel(twinVault.poolPrice(), 161e18, 1e12);
    }

    function test_AMoveWhileOpenIsFollowedWithoutAHalt() public {
        _publish(MarketTypes.OPEN, 133e18); // -5% on the tape, no halt

        assertApproxEqRel(vault.poolPrice(), 133e18, 1e12);
        assertApproxEqRel(vault.valueAt(133e18), _hodlValue(133e18), 1e9);
        assertEq(_raid(PROTECTED), 0);
        assertGt(_raid(TWIN), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // After hours
    // ---------------------------------------------------------------------------------------------

    function test_ClosingBellSwitchesToAfterHoursMode() public {
        _publish(MarketTypes.CLOSED, START_PRICE);

        (bool tradable, uint24 fee) = hook.quote(poolKey.toId());
        assertTrue(tradable, "the token keeps trading after the bell");
        assertEq(fee, CLOSED_FEE);

        uint256 lower = PriceMath.toRatioWad(TickMath.getSqrtPriceAtTick(vault.tickLower()));
        uint256 upper = PriceMath.toRatioWad(TickMath.getSqrtPriceAtTick(vault.tickUpper()));
        if (!_stockIsCurrency0()) (lower, upper) = (PriceMath.invert(upper), PriceMath.invert(lower));
        assertApproxEqRel(lower, START_PRICE * 85 / 100, 0.002e18, "wide band, lower edge");
        assertApproxEqRel(upper, START_PRICE * 115 / 100, 0.002e18, "wide band, upper edge");

        trader.swap(poolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        assertEq(_lastSwapFee(), CLOSED_FEE, "after-hours fee is charged");
    }

    function test_OvernightGapIsAbsorbedAtTheOpeningBell() public {
        _publish(MarketTypes.CLOSED, START_PRICE);
        _publish(MarketTypes.OPEN, 154e18); // earnings beat: +10% at the open

        assertApproxEqRel(vault.poolPrice(), 154e18, 1e12);
        assertApproxEqRel(vault.valueAt(154e18), _hodlValue(154e18), 1e9);
        (, uint24 fee) = hook.quote(poolKey.toId());
        assertEq(fee, OPEN_FEE);
        assertEq(_raid(PROTECTED), 0);
        assertGt(_raid(TWIN), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Guard rails
    // ---------------------------------------------------------------------------------------------

    function test_OnlyTheVaultCanProvideLiquidity() public {
        vm.expectRevert();
        trader.addLiquidity(poolKey, -TICK_SPACING * 10, TICK_SPACING * 10, 1e18);
    }

    function test_APoolWithNoMarketDataDoesNotTrade() public {
        PoolKey memory fresh = PoolKey(
            poolKey.currency0, poolKey.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 2, IHooks(address(hook))
        );
        POOL_MANAGER.initialize(fresh, _sqrt(START_PRICE));
        hook.registerPool(fresh, BellHook.PoolConfig(keccak256("TSLA/USD"), address(vault), false, 0, 0, 0));

        (bool tradable,) = hook.quote(fresh.toId());
        assertFalse(tradable);
        vm.expectRevert();
        trader.swap(fresh, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_AnUnregisteredPoolDoesNotTrade() public {
        PoolKey memory rogue = PoolKey(
            poolKey.currency0, poolKey.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 3, IHooks(address(hook))
        );
        POOL_MANAGER.initialize(rogue, _sqrt(START_PRICE));
        vm.expectRevert();
        trader.swap(rogue, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_StaleOpenStateFallsBackToTheStaleFee() public {
        hook.registerPool(poolKey, BellHook.PoolConfig(NVDA, address(vault), false, 0, 600, CLOSED_FEE));

        (, uint24 fee) = hook.quote(poolKey.toId());
        assertEq(fee, OPEN_FEE);

        skip(601); // ten minutes of silence while the market is supposedly open
        (, fee) = hook.quote(poolKey.toId());
        assertEq(fee, CLOSED_FEE);

        trader.swap(poolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        assertEq(_lastSwapFee(), CLOSED_FEE);
    }

    function test_VaultDriversAreRestricted() public {
        vm.startPrank(player);
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.onMarketState(NVDA, MarketTypes.OPEN, 1e18, 0, 100);
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.catchUp();
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.reposition(1e18, 100);
        vm.expectRevert(BellVault.NotPoolManager.selector);
        vault.unlockCallback("");
        vm.expectRevert(Arena.NotPoolManager.selector);
        arena.unlockCallback("");
        vm.expectRevert(Arena.NotSelf.selector);
        arena.attempt(0, 1e18);
        vm.stopPrank();
    }

    function test_OrdinaryTradingEarnsFeesForTheVault() public {
        uint256 before = vault.valueAt(START_PRICE);

        // A round trip by an ordinary trader: buys then sells the same amount of stock.
        bool buyIsZeroForOne = !_stockIsCurrency0();
        trader.swap(
            poolKey, buyIsZeroForOne, 10e18, buyIsZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        trader.swap(
            poolKey,
            !buyIsZeroForOne,
            -10e18,
            buyIsZeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
        );

        // Fees are collected the next time the vault moves.
        _publish(MarketTypes.OPEN, START_PRICE + 0.5e18);
        assertGt(vault.valueAt(START_PRICE), before, "fees were collected");
    }

    // ---------------------------------------------------------------------------------------------
    // Randomised days
    // ---------------------------------------------------------------------------------------------

    /// @dev However the market moves, once the Reactive Network has delivered an update the protected
    ///      pool cannot be raided for profit, and the vault has lost nothing to anyone.
    function testFuzz_ProtectedPoolIsNeverRaidable(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 12));
        uint256 price = START_PRICE;

        for (uint256 i = 0; i != steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint8 status = uint8(seed % 3);
            // Moves between -20% and +20%.
            price = price * (8_000 + ((seed >> 8) % 4_001)) / 10_000;
            price = bound(price, 1e18, 100_000e18);

            _publish(status, price);

            int256 pnl = _raid(PROTECTED);
            assertLe(pnl, 0, "raider never profits");

            if (status != MarketTypes.HALTED) {
                assertApproxEqRel(vault.poolPrice(), price, 1e12, "pool follows the market");
            }
            assertGe(vault.valueAt(price) + 1e12, _hodlValue(price), "vault lost nothing");
        }

        assertEq(_count(address(guard), LISTENER_FAILED_SIG), 0, "the vault never failed");
        assertEq(reactionReverts + deliveryFailures, 0);
        assertLe(arena.taken(PROTECTED), 0);
    }
}

contract BellPoolStock0Test is BellPoolBase {
    function _stockIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract BellPoolStock1Test is BellPoolBase {
    function _stockIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
