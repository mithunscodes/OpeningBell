// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "v4-core/types/PoolOperation.sol";
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
    bytes32 internal constant REFILLED_SIG = keccak256("Refilled(uint256,uint256,uint256)");
    bytes32 internal constant RAID_BLOCKED_SIG = keccak256("RaidBlocked(address,uint256)");
    bytes32 internal constant RAID_POINTLESS_SIG = keccak256("RaidPointless(address,uint256,uint256,uint256)");
    bytes32 internal constant LISTENER_FAILED_SIG = keccak256("ListenerFailed(bytes32,address,bytes)");
    bytes32 internal constant REPOSITIONED_SIG = keccak256("Repositioned(uint256,uint24,int24,int24,uint128,uint160)");

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
        arena.setTarget(PROTECTED, poolKey, vault, false, 0, 0);
        arena.setTarget(TWIN, twinKey, twinVault, true, START_STOCK, START_DOLLARS);
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

        assertEq(_raid(PROTECTED), 0);
        assertEq(arena.blocked(PROTECTED), 1);
        assertEq(_count(address(arena), RAID_BLOCKED_SIG), 1);
    }

    function test_BadNewsDuringAHaltCannotBeTradedOn() public {
        _publish(MarketTypes.HALTED, START_PRICE);
        // The news is bad: the stock will reopen 10% lower, and the feed already says so. The raider
        // moves before the Reactive Network has delivered that second update.
        vm.prank(publisher);
        feed.publish(NVDA, MarketTypes.HALTED, 126e18, uint64(block.timestamp));

        vm.prank(player);
        int256 pnl = arena.raid(PROTECTED);

        assertEq(pnl, 0, "the pool was already shut by the first update");
        assertEq(arena.blocked(PROTECTED), 1);
        _pump();
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

        // Every dollar the raider made came out of the twin (which kept the swap fee). The arena then
        // refilled the twin with play money, so that has to be taken out of the comparison.
        Vm.Log memory refill = _last(address(arena), REFILLED_SIG);
        (uint256 refillStock, uint256 refillDollars) = abi.decode(refill.data, (uint256, uint256));
        uint256 lost = before + refillDollars + refillStock * 126 - twinVault.valueAt(126e18);
        assertApproxEqRel(lost, uint256(pnl), 0.01e18, "raider's gain is the twin's loss");

        assertEq(arena.loot(player), pnl);
        assertEq(arena.taken(TWIN), pnl);
        assertEq(arena.taken(PROTECTED), 0);

        // Afterwards the twin's manager catches up, too late.
        assertApproxEqRel(twinVault.poolPrice(), 126e18, 1e12);
        assertEq(_raid(TWIN), 0);
    }

    function test_TheTwinIsRefilledSoItCanBeRaidedAgain() public {
        _publish(MarketTypes.OPEN, 126e18);
        int256 first = _raid(TWIN);
        assertGt(first, 0);

        // After the raid the twin held almost no dollars. The arena topped it up and it caught up.
        (uint256 stockHeld, uint256 dollarsHeld) = twinVault.holdings();
        assertGe(stockHeld, START_STOCK);
        assertApproxEqRel(dollarsHeld, START_DOLLARS, 0.001e18);
        assertApproxEqRel(twinVault.poolPrice(), 126e18, 1e12);

        _publish(MarketTypes.OPEN, 113.4e18);
        int256 second = _raid(TWIN);
        assertGt(second, 0, "raided again");
        assertEq(arena.taken(TWIN), first + second);
        assertEq(arena.raids(TWIN), 2);

        // The protected vault was never refilled and never needed it.
        assertEq(arena.taken(PROTECTED), 0);
        assertApproxEqRel(vault.valueAt(113.4e18), _hodlValue(113.4e18), 1e9);
    }

    function test_ARaidStartedWithTooLittleGasRevertsInsteadOfLookingBlocked() public {
        _publish(MarketTypes.OPEN, 126e18);

        // With too little gas the swap inside the raid would fail and be mistaken for a refusal.
        vm.prank(player);
        vm.expectRevert(Arena.NotEnoughGas.selector);
        arena.raid{ gas: 700_000 }(TWIN);
        assertEq(arena.blocked(TWIN), 0, "not counted as blocked");

        // The minimum is enough for the costliest raid there is: the twin, with refill and reposition.
        vm.prank(player);
        uint256 gasBefore = gasleft();
        int256 pnl = arena.raid{ gas: arena.MIN_RAID_GAS() + 10_000 }(TWIN);
        uint256 used = gasBefore - gasleft();
        assertGt(pnl, 0, "the raid went through");
        assertLt(used, arena.MIN_RAID_GAS() * 9 / 10, "with room to spare");
        emit log_named_uint("gas used by a twin raid", used);
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
        arena.attempt(0, 1e18, 0);
        vm.stopPrank();
    }

    function test_VaultEdgeCasesAndOwnerControls() public {
        vm.prank(address(guard));
        vm.expectRevert(BellVault.WrongMarket.selector);
        vault.onMarketState(keccak256("TSLA/USD"), MarketTypes.OPEN, 1e18, 0, 100);

        vm.expectRevert(BellVault.BadRange.selector);
        vault.reposition(START_PRICE, 10_000);

        // Idle tokens can be taken out by the owner only.
        dollars.mint(address(vault), 5e18);
        vm.prank(player);
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.withdraw(address(dollars), player, 5e18);
        vault.withdraw(address(dollars), player, 5e18);
        assertEq(dollars.balanceOf(player), 5e18);

        vm.prank(player);
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.transferOwnership(player);
        vault.transferOwnership(player);
        assertEq(vault.owner(), player);
        vm.expectRevert(BellVault.NotAuthorized.selector);
        vault.setKeeper(address(this));
    }

    function test_AVaultWithNoMarketDataStaysPut() public {
        // A fresh guard has heard nothing, so catching up is a no-op.
        BellGuard quiet = new BellGuard(IPayable(payable(address(_proxy(BASE_SEPOLIA)))), address(conductor));
        BellVault idle = new BellVault(POOL_MANAGER, quiet, NVDA, poolKey, address(stock));
        idle.catchUp();
        _pump();
        (uint256 s, uint256 d) = idle.holdings();
        assertEq(s + d, 0);
        assertEq(_count(address(idle), REPOSITIONED_SIG), 0, "it did not even try");
    }

    function test_UnusedHooksRefuseToRun() public {
        ModifyLiquidityParams memory mp;
        SwapParams memory sp;
        BalanceDelta zero;

        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(0), poolKey, 0);
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), poolKey, 0, 0);
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(0), poolKey, mp, zero, zero, "");
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), poolKey, mp, "");
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(0), poolKey, mp, zero, zero, "");
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.afterSwap(address(0), poolKey, sp, zero, "");
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.beforeDonate(address(0), poolKey, 0, 0, "");
        vm.expectRevert(BellHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), poolKey, 0, 0, "");

        // The two hooks in use answer only to the pool manager.
        vm.expectRevert(BellHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, sp, "");
        vm.expectRevert(BellHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(vault), poolKey, mp, "");
    }

    function test_HookRegistrationRules() public {
        PoolKey memory wrongHook = poolKey;
        wrongHook.hooks = IHooks(address(0x1234));
        vm.expectRevert(BellHook.WrongHook.selector);
        hook.registerPool(wrongHook, BellHook.PoolConfig(NVDA, address(vault), false, 0, 0, 0));

        PoolKey memory fixedFee = poolKey;
        fixedFee.fee = 3000;
        vm.expectRevert(BellHook.NotDynamicFee.selector);
        hook.registerPool(fixedFee, BellHook.PoolConfig(NVDA, address(vault), false, 0, 0, 0));

        vm.startPrank(player);
        vm.expectRevert(BellHook.NotOwner.selector);
        hook.registerPool(poolKey, BellHook.PoolConfig(NVDA, player, false, 0, 0, 0));
        vm.expectRevert(BellHook.NotOwner.selector);
        hook.transferOwnership(player);
        vm.stopPrank();

        hook.transferOwnership(player);
        assertEq(hook.owner(), player);
    }

    function test_ScoutShowsWhatARaidWouldFind() public {
        Arena.Target memory t = arena.target(TWIN);
        assertEq(address(t.vault), address(twinVault));
        assertTrue(t.catchUpAfter);

        _publish(MarketTypes.HALTED, START_PRICE);
        (uint256 poolPrice, uint256 refPrice, bool tradable,) = arena.scout(PROTECTED);
        assertEq(refPrice, START_PRICE);
        assertApproxEqRel(poolPrice, START_PRICE, 1e15);
        assertFalse(tradable, "halted pool is not tradable");

        (,, tradable,) = arena.scout(TWIN);
        assertTrue(tradable, "the twin never stops");

        vm.expectRevert(Arena.UnknownTarget.selector);
        arena.scout(7);
        vm.expectRevert(Arena.UnknownTarget.selector);
        arena.raid(7);

        vm.prank(player);
        vm.expectRevert(Arena.NotOwner.selector);
        arena.setTarget(7, poolKey, vault, false, 0, 0);
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
    // Details that mutation testing found unchecked
    // ---------------------------------------------------------------------------------------------

    /// @dev The reason a hook gave, from inside the pool manager's `WrappedError`.
    function _hookReason(bytes memory err) internal pure returns (bytes4) {
        assertEq(bytes32(bytes4(err)), bytes32(CustomRevert.WrappedError.selector), "a hook refused");
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i != body.length; ++i) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }

    function test_TheHookChecksFeesAnnouncesPoolsAndQuotesUnknownOnesAsClosed() public {
        PoolKey memory fresh = PoolKey(
            poolKey.currency0, poolKey.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 5, IHooks(address(hook))
        );
        (bool tradable, uint24 fee) = hook.quote(fresh.toId());
        assertFalse(tradable);
        assertEq(fee, 0);

        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, uint24(1_000_001)));
        hook.registerPool(fresh, BellHook.PoolConfig(NVDA, address(vault), true, 1_000_001, 0, 0));
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, uint24(1_000_001)));
        hook.registerPool(fresh, BellHook.PoolConfig(NVDA, address(vault), false, 0, 600, 1_000_001));

        vm.expectEmit(true, true, false, true, address(hook));
        emit BellHook.PoolRegistered(fresh.toId(), NVDA, address(vault), true);
        hook.registerPool(fresh, BellHook.PoolConfig(NVDA, address(vault), true, 1_000_000, 0, 0));
    }

    function test_AnUnregisteredPoolIsRefusedAsUnregistered() public {
        PoolKey memory rogue = PoolKey(
            poolKey.currency0, poolKey.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 3, IHooks(address(hook))
        );
        POOL_MANAGER.initialize(rogue, _sqrt(START_PRICE));
        try trader.swap(rogue, true, -1e18, TickMath.MIN_SQRT_PRICE + 1) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes32(_hookReason(err)), bytes32(BellHook.PoolNotRegistered.selector));
        }
        try trader.addLiquidity(rogue, -TICK_SPACING * 10, TICK_SPACING * 10, 1e18) {
            fail();
        } catch (bytes memory err) {
            assertEq(bytes32(_hookReason(err)), bytes32(BellHook.PoolNotRegistered.selector));
        }
    }

    function test_AVaultCanPlaceItsPoolBeforeAnyMarketData() public {
        bytes32 tsla = keccak256("TSLA/USD");
        PoolKey memory fresh = PoolKey(
            poolKey.currency0, poolKey.currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING + 4, IHooks(address(hook))
        );
        POOL_MANAGER.initialize(fresh, _sqrt(START_PRICE));
        BellVault early = new BellVault(POOL_MANAGER, guard, tsla, fresh, address(stock));
        hook.registerPool(fresh, BellHook.PoolConfig(tsla, address(early), false, 0, 0, 0));

        // With nothing to put in, the vault only moves the empty pool.
        vm.expectEmit(false, false, false, false, address(early));
        emit BellVault.Repositioned(0, 0, 0, 0, 0, 0);
        early.reposition(150e18, OPEN_RANGE);
        assertEq(early.liquidity(), 0);
        assertApproxEqRel(early.poolPrice(), 150e18, 1e12);

        // With tokens, it provides liquidity, although the guard has never heard of this market.
        stock.mint(address(early), 10e18);
        dollars.mint(address(early), 1_500e18);
        early.reposition(160e18, OPEN_RANGE);
        assertGt(early.liquidity(), 0);
        assertApproxEqRel(early.poolPrice(), 160e18, 1e12);

        vm.expectEmit(false, false, false, true, address(early));
        emit BellVault.KeeperSet(player);
        early.setKeeper(player);
    }

    function test_TheVaultRefusesOtherMarketsAndImpossibleBands() public {
        vm.startPrank(address(guard));
        vm.expectRevert(BellVault.WrongMarket.selector);
        vault.onMarketState(bytes32(type(uint256).max), MarketTypes.OPEN, 1e18, 0, 100);
        vm.expectRevert(BellVault.WrongMarket.selector);
        vault.onMarketState(bytes32(0), MarketTypes.OPEN, 1e18, 0, 100);
        vm.stopPrank();
        vm.expectRevert(BellVault.BadRange.selector);
        vault.reposition(START_PRICE, 10_001);
    }

    function _gridFloor(int24 tick) internal pure returns (int24) {
        int256 t = tick;
        int256 s = TICK_SPACING;
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(t >= 0 ? (t / s) * s : -(((-t) + s - 1) / s) * s);
    }

    function _expectedBand(uint256 price, uint24 half) internal pure returns (int24 lower, int24 upper) {
        uint160 a = _sqrt(price * (10_000 - half) / 10_000);
        uint160 b = _sqrt(price * (10_000 + half) / 10_000);
        if (a > b) (a, b) = (b, a);
        lower = _gridFloor(TickMath.getTickAtSqrtPrice(a));
        upper = _gridFloor(TickMath.getTickAtSqrtPrice(b)) + TICK_SPACING;
    }

    function test_TheBandSitsExactlyOnTheTickGrid() public {
        uint256[5] memory prices = [uint256(140e18), 126e18, 151.01e18, 0.37e18, 2_345.6e18];
        for (uint256 i = 0; i != prices.length; ++i) {
            vault.reposition(prices[i], OPEN_RANGE);
            (int24 lower, int24 upper) = _expectedBand(prices[i], OPEN_RANGE);
            assertEq(vault.tickLower(), lower, "lower edge");
            assertEq(vault.tickUpper(), upper, "upper edge");
        }

        // A lower edge that falls exactly on a negative multiple of the spacing stays there.
        int24 t = -50_000;
        uint256 inside = uint256(TickMath.getSqrtPriceAtTick(t)) * 100_002 / 100_000;
        uint256 ratio = FullMath.mulDiv(inside * inside, 1e18, 1 << 192);
        uint256 price = _stockIsCurrency0()
            ? ratio * 10_000 / (10_000 - OPEN_RANGE)
            : PriceMath.invert(ratio) * 10_000 / (10_000 + OPEN_RANGE);
        vault.reposition(price, OPEN_RANGE);
        assertEq(vault.tickLower(), t, "already on the grid, not moved down");
    }

    function _swapFee() internal returns (uint24) {
        trader.swap(poolKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        return _lastSwapFee();
    }

    function test_TheStaleFeeStartsExactlyWhenTheAllowedSilenceEnds() public {
        uint24 staleFee = 10_000;
        vm.warp(1_800_000_000);
        hook.registerPool(poolKey, BellHook.PoolConfig(NVDA, address(vault), false, 0, 600, staleFee));
        _publish(MarketTypes.OPEN, START_PRICE);

        uint256[4] memory ages = [uint256(0), 300, 600, 601];
        for (uint256 i = 0; i != ages.length; ++i) {
            vm.warp(1_800_000_000 + ages[i]);
            uint24 expected = ages[i] > 600 ? staleFee : OPEN_FEE;
            (, uint24 quoted) = hook.quote(poolKey.toId());
            assertEq(quoted, expected, "quote");
            assertEq(_swapFee(), expected, "charged");
        }

        // After hours the closed fee applies, however long the silence.
        _publish(MarketTypes.CLOSED, START_PRICE);
        skip(601);
        (, uint24 closedQuote) = hook.quote(poolKey.toId());
        assertEq(closedQuote, CLOSED_FEE);
        assertEq(_swapFee(), CLOSED_FEE);

        // A pool with no staleness limit never falls back.
        hook.registerPool(poolKey, BellHook.PoolConfig(NVDA, address(vault), false, 0, 0, staleFee));
        _publish(MarketTypes.OPEN, START_PRICE);
        skip(100_000);
        (, uint24 openQuote) = hook.quote(poolKey.toId());
        assertEq(openQuote, OPEN_FEE);
        assertEq(_swapFee(), OPEN_FEE);
    }

    function test_TheTwinChargesItsOwnFeeAndNeverStops() public {
        trader.swap(twinKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        assertEq(_lastSwapFee(), OPEN_FEE);

        _publish(MarketTypes.HALTED, START_PRICE);
        trader.swap(twinKey, true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        _pump();
        assertEq(_lastSwapFee(), OPEN_FEE, "the twin ignores the halt");
    }

    function test_EveryRaidIsReportedAgainstTheRaider() public {
        vm.expectEmit(true, false, false, true, address(arena));
        emit Arena.TargetSet(9, twinKey.toId(), address(twinVault), false);
        arena.setTarget(9, twinKey, twinVault, false, 0, 0);

        vm.expectEmit(true, true, false, false, address(arena));
        emit Arena.RaidPointless(player, TWIN, 0, 0);
        _raid(TWIN);

        _publish(MarketTypes.OPEN, 126e18);
        vm.expectEmit(true, true, false, false, address(arena));
        emit Arena.Raid(player, TWIN, false, 0, 0, 0, 0, 0);
        int256 first = _raid(TWIN);
        _publish(MarketTypes.OPEN, 113.4e18);
        int256 second = _raid(TWIN);
        assertEq(arena.loot(player), first + second, "loot adds up");

        _publish(MarketTypes.HALTED, 113.4e18);
        vm.expectEmit(true, true, false, false, address(arena));
        emit Arena.RaidBlocked(player, PROTECTED);
        _raid(PROTECTED);
    }

    function test_ARaidThePoolCannotSettleIsCountedAsBlocked() public {
        arena.setTarget(9, twinKey, twinVault, false, 0, 0);
        _publish(MarketTypes.OPEN, 126e18);

        // The arena pays raids with play money it mints. Without that right the swap cannot be paid for.
        stock.setMinter(address(arena), false);
        dollars.setMinter(address(arena), false);
        vm.expectEmit(true, true, false, false, address(arena));
        emit Arena.RaidBlocked(player, 9);
        assertEq(_raid(9), 0);
        assertEq(arena.blocked(9), 1);
        assertEq(arena.loot(player), 0);
    }

    function test_TheTwinIsToppedUpToExactlyWhatItStartedWith() public {
        // Small moves, so the raid leaves the twin holding plenty of the token it gave up.
        _publish(MarketTypes.OPEN, 138.6e18);
        assertGt(_raid(TWIN), 0);
        (uint256 stockHeld, uint256 dollarsHeld) = twinVault.holdings();
        assertGt(stockHeld, START_STOCK, "it took stock");
        assertApproxEqAbs(dollarsHeld, START_DOLLARS, 1e9, "dollars topped up exactly");

        _publish(MarketTypes.OPEN, 141e18);
        assertGt(_raid(TWIN), 0);
        (stockHeld,) = twinVault.holdings();
        assertApproxEqAbs(stockHeld, START_STOCK, 1e9, "stock topped up exactly");

        // A big move empties the twin of stock altogether; it is still topped up to the same amount.
        _publish(MarketTypes.OPEN, 155.1e18);
        assertGt(_raid(TWIN), 0);
        (stockHeld,) = twinVault.holdings();
        assertApproxEqAbs(stockHeld, START_STOCK, 1e9, "stock topped up exactly after a big move");
        assertEq(_count(address(arena), REFILLED_SIG), 3);

        // A target with nothing to top up reports no refill.
        arena.setTarget(10, twinKey, twinVault, true, 0, 0);
        _raid(10);
        assertEq(_count(address(arena), REFILLED_SIG), 3);
    }

    function test_AnyTargetNumberWorks() public {
        uint256 far = uint256(1) << 200;
        arena.setTarget(far, twinKey, twinVault, false, 0, 0);
        vm.expectEmit(true, true, false, false, address(arena));
        emit Arena.RaidPointless(player, far, 0, 0);
        assertEq(_raid(far), 0);
        assertEq(arena.blocked(far), 0);
    }

    function test_AMarketWithNoReferencePriceIsNeverRaided() public {
        Arena blind = new Arena(POOL_MANAGER, feed, keccak256("TSLA/USD"), stock, dollars);
        blind.setTarget(0, twinKey, twinVault, false, 0, 0);
        vm.expectEmit(true, true, false, false, address(blind));
        emit Arena.RaidPointless(player, 0, 0, 0);
        vm.prank(player);
        assertEq(blind.raid(0), 0);
        assertEq(blind.blocked(0), 0);
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
