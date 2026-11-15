// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { OmniTest } from "./harness/OmniTest.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { BellReactive } from "../src/reactive/BellReactive.sol";
import { BellWatchdog } from "../src/reactive/BellWatchdog.sol";
import { BellGuard } from "../src/venue/BellGuard.sol";

/// @notice Stand-in for the legacy system contract, which emits the network's clock events.
contract MockClock {
    event Cron10(uint256 indexed number);

    function tick() external {
        emit Cron10(block.number);
    }
}

/// @notice The watchdog on top of the full loop: feed on Base, conductor and watchdog on Reactive,
///         guards on Base and Unichain.
contract BellWatchdogTest is OmniTest {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");
    bytes32 internal constant TSLA = keccak256("TSLA/USD");

    bytes32 internal constant WATCHING_SIG = keccak256("Watching(bytes32,uint64)");
    bytes32 internal constant RETRIED_SIG = keccak256("Retried(bytes32,uint64,uint256,uint8)");
    bytes32 internal constant REFUSED_SIG = keccak256("RetryRefused(bytes32,uint256,bytes)");
    bytes32 internal constant SETTLED_SIG = keccak256("Settled(bytes32,uint64,uint8)");
    bytes32 internal constant GAVE_UP_SIG = keccak256("GaveUp(bytes32,uint64,uint8)");
    bytes32 internal constant TICKING_SIG = keccak256("Ticking(bool)");
    bytes32 internal constant LOOP_CLOSED_SIG = keccak256("LoopClosed(bytes32,uint64)");

    uint64 internal constant RETRY_AFTER = 8;
    uint8 internal constant MAX_RETRIES = 3;

    address internal publisher = makeAddr("publisher");
    address internal stranger = makeAddr("stranger");

    MarketFeed internal feed;
    BellReactive internal conductor;
    BellWatchdog internal watchdog;
    BellGuard internal baseGuard;
    BellGuard internal uniGuard;
    MockClock internal clock;

    function setUp() public {
        _omniSetUp();

        feed = new MarketFeed();
        feed.setPublisher(publisher, true);
        _place(address(feed), BASE_SEPOLIA);

        conductor = new BellReactive(BASE_SEPOLIA, address(feed), BellReactive.AckMode.Always);
        _place(address(conductor), LASNA);

        baseGuard = new BellGuard(IPayable(payable(address(_proxy(BASE_SEPOLIA)))), address(conductor));
        uniGuard = new BellGuard(IPayable(payable(address(_proxy(UNICHAIN_SEPOLIA)))), address(conductor));
        _place(address(baseGuard), BASE_SEPOLIA);
        _place(address(uniGuard), UNICHAIN_SEPOLIA);

        conductor.addVenue(BASE_SEPOLIA, address(baseGuard), 300_000, 10, _policy());
        conductor.addVenue(UNICHAIN_SEPOLIA, address(uniGuard), 300_000, 10, _policy());

        watchdog = new BellWatchdog(conductor, RETRY_AFTER, MAX_RETRIES);
        conductor.transferOwnership(address(watchdog));

        // The network's clock lives at a fixed address on Reactive Network itself.
        vm.etch(watchdog.CLOCK(), address(new MockClock()).code);
        clock = MockClock(watchdog.CLOCK());
        _place(address(clock), block.chainid);

        _pump(); // flush set-up logs
    }

    function _policy() internal pure returns (BellReactive.Policy[3] memory p) {
        p[MarketTypes.CLOSED] = BellReactive.Policy(30_000, 1_500);
        p[MarketTypes.OPEN] = BellReactive.Policy(500, 100);
        p[MarketTypes.HALTED] = BellReactive.Policy(0, 0);
    }

    function _publish(bytes32 marketId, uint8 status, uint256 price) internal returns (uint64 seq) {
        vm.prank(publisher);
        seq = feed.publish(marketId, status, price, uint64(block.timestamp));
        _pump();
    }

    function _publish(uint8 status, uint256 price) internal returns (uint64 seq) {
        return _publish(NVDA, status, price);
    }

    /// @dev Lets `blocks` pass on Reactive Network, then rings the clock once.
    function _tick(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        clock.tick();
        _pump();
    }

    function _status(BellGuard guard) internal view returns (uint8 status, uint64 seq) {
        (status,,,, seq,) = guard.current(NVDA);
    }

    function _watch(bytes32 marketId) internal view returns (uint64 seq, uint64 sinceBlock, uint8 retries, bool open) {
        return watchdog.watches(marketId);
    }

    // ------------------------------------------------------------------------------------------
    // The healthy path
    // ------------------------------------------------------------------------------------------

    function test_AHealthyLoopIsWatchedThenLeftAlone() public {
        uint256 requestsBefore = requests;
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);

        (uint64 watched,,, bool open) = _watch(NVDA);
        assertEq(watched, seq);
        assertTrue(open);
        assertTrue(watchdog.ticking(), "the clock is on while a loop is open");
        assertEq(requests - requestsBefore, 2, "one callback per venue, as before");

        _tick(10);

        assertEq(_count(address(watchdog), SETTLED_SIG), 1);
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
        assertEq(requests - requestsBefore, 2, "nothing was sent twice");
        assertFalse(watchdog.ticking(), "the clock is off again");
        assertEq(watchdog.openWatches().length, 0);
    }

    function test_AQuietMarketCostsNothing() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);

        uint256 reactionsBefore = reactions;
        _tick(10);
        _tick(10);
        _tick(10);
        assertEq(reactions, reactionsBefore, "no subscription, so no reactive transaction");
    }

    function test_ATickBeforeTheDeadlineOnlyLooks() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);

        _tick(RETRY_AFTER - 1);

        assertEq(_count(address(watchdog), RETRIED_SIG), 0, "too early to call it a miss");
        assertTrue(watchdog.ticking());
    }

    function test_ASmallPriceMoveThatIsNotForwardedSettlesAtOnce() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);

        // 0.05% is under the venues' 0.10% threshold: the conductor forwards nothing.
        uint256 requestsBefore = requests;
        _publish(MarketTypes.OPEN, 100.05e18);
        assertEq(requests, requestsBefore);
        assertTrue(watchdog.ticking());

        _tick(10);
        assertEq(_count(address(watchdog), SETTLED_SIG), 2);
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
        assertFalse(watchdog.ticking());
    }

    // ------------------------------------------------------------------------------------------
    // A venue misses an update
    // ------------------------------------------------------------------------------------------

    function test_AMissedVenueIsSentTheStateAgainWithoutAnyone() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);

        // Unichain is unreachable while the halt goes out.
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);

        (uint8 baseStatus,) = _status(baseGuard);
        (uint8 uniStatus,) = _status(uniGuard);
        assertEq(baseStatus, MarketTypes.HALTED);
        assertEq(uniStatus, MarketTypes.OPEN, "Unichain missed the halt");
        assertFalse(conductor.inSync(NVDA));

        // It comes back. Nobody calls anything: the next tick of the clock does the work.
        _chainDown[UNICHAIN_SEPOLIA] = false;
        uint256 deliveriesBefore = deliveries;
        _tick(10);

        assertEq(deliveries - deliveriesBefore, 1, "only the venue that missed gets a callback");
        uint64 uniSeq;
        (uniStatus, uniSeq) = _status(uniGuard);
        assertEq(uniStatus, MarketTypes.HALTED, "Unichain caught up");
        assertEq(uniSeq, seq);
        assertTrue(conductor.inSync(NVDA));
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 2, "the loop closed on-chain");

        Vm.Log memory retried = _last(address(watchdog), RETRIED_SIG);
        assertEq(retried.topics[1], NVDA);
        assertEq(uint256(retried.topics[2]), seq);
        assertEq(uint256(retried.topics[3]), 1, "venue 1 is Unichain");
        assertEq(abi.decode(retried.data, (uint8)), 1, "first attempt");

        // The tick after that sees a closed loop and switches the clock off.
        _tick(10);
        Vm.Log memory settled = _last(address(watchdog), SETTLED_SIG);
        assertEq(abi.decode(settled.data, (uint8)), 1, "settled after one round of re-sends");
        assertFalse(watchdog.ticking());
    }

    function test_ItKeepsTryingWhileTheVenueIsDown() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);

        _tick(10); // attempt 1, lost
        _tick(10); // attempt 2, lost
        assertEq(_count(address(watchdog), RETRIED_SIG), 2);

        _chainDown[UNICHAIN_SEPOLIA] = false;
        _tick(10); // attempt 3, lands

        (uint8 uniStatus, uint64 uniSeq) = _status(uniGuard);
        assertEq(uniStatus, MarketTypes.OPEN);
        assertEq(uniSeq, seq);
        assertTrue(conductor.inSync(NVDA));

        _tick(10);
        Vm.Log memory settled = _last(address(watchdog), SETTLED_SIG);
        assertEq(abi.decode(settled.data, (uint8)), 3);
    }

    function test_ItGivesUpLoudlyAndStopsPaying() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);

        for (uint256 i = 0; i != MAX_RETRIES; ++i) {
            _tick(10);
        }
        assertEq(_count(address(watchdog), RETRIED_SIG), MAX_RETRIES);
        assertEq(_count(address(watchdog), GAVE_UP_SIG), 0);
        assertTrue(watchdog.ticking());

        _tick(10);

        Vm.Log memory gaveUp = _last(address(watchdog), GAVE_UP_SIG);
        assertEq(uint256(gaveUp.topics[2]), seq);
        assertEq(abi.decode(gaveUp.data, (uint8)), MAX_RETRIES);
        assertFalse(watchdog.ticking(), "a dead venue must not drain the watchdog");

        uint256 reactionsBefore = reactions;
        _tick(10);
        assertEq(reactions, reactionsBefore);
    }

    function test_TheNextUpdateStartsAFreshCountAndCarriesTheLaggingVenue() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);
        for (uint256 i = 0; i != MAX_RETRIES + 1; ++i) {
            _tick(10);
        }
        assertEq(_count(address(watchdog), GAVE_UP_SIG), 1);

        // Unichain is back. The next update reaches it, and the watchdog watches that loop from zero.
        _chainDown[UNICHAIN_SEPOLIA] = false;
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);
        (,, uint8 retries, bool open) = _watch(NVDA);
        assertTrue(open);
        assertEq(retries, 0);

        (uint8 uniStatus, uint64 uniSeq) = _status(uniGuard);
        assertEq(uniStatus, MarketTypes.HALTED);
        assertEq(uniSeq, seq);

        _tick(10);
        assertEq(_count(address(watchdog), SETTLED_SIG), 1);
        assertFalse(watchdog.ticking());
    }

    function test_ANewerUpdateResetsTheDeadline() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);

        vm.roll(block.number + RETRY_AFTER - 1);
        _publish(MarketTypes.HALTED, 100e18);
        // One block later the first update's deadline would have passed. The second one's has not.
        _tick(1);

        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
    }

    function test_TwoMarketsAreWatchedSideBySide() public {
        _publish(NVDA, MarketTypes.OPEN, 100e18);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(TSLA, MarketTypes.OPEN, 250e18);
        _chainDown[UNICHAIN_SEPOLIA] = false;
        assertEq(watchdog.openWatches().length, 2);

        _tick(10);

        assertEq(_count(address(watchdog), SETTLED_SIG), 1, "NVDA was fine");
        assertEq(_count(address(watchdog), RETRIED_SIG), 1, "TSLA was re-sent to Unichain");
        (uint8 status,,,, uint64 uniSeq,) = uniGuard.current(TSLA);
        assertEq(status, MarketTypes.OPEN);
        assertEq(uniSeq, seq);
        assertTrue(watchdog.ticking(), "TSLA is still open until the next look");

        _tick(10);
        assertEq(_count(address(watchdog), SETTLED_SIG), 2);
        assertFalse(watchdog.ticking());
    }

    function test_AnInactiveVenueIsNotChased() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);

        watchdog.execute(
            address(conductor), abi.encodeCall(BellReactive.updateVenue, (1, 300_000, 10, false, _policy()))
        );
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.HALTED, 100e18);

        _tick(10);
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
        assertEq(_count(address(watchdog), SETTLED_SIG), 2);
    }

    // ------------------------------------------------------------------------------------------
    // Things that must not hurt
    // ------------------------------------------------------------------------------------------

    function test_AConductorThatIsBehindIsWaitedForNotResent() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);

        // A paused conductor ignores the update, so its books still describe the previous one.
        watchdog.execute(address(conductor), abi.encodeCall(BellReactive.setPaused, (true)));
        uint256 requestsBefore = requests;
        _publish(MarketTypes.HALTED, 100e18);

        for (uint256 i = 0; i != MAX_RETRIES; ++i) {
            _tick(10);
        }
        assertEq(requests, requestsBefore, "nothing to re-send: the conductor never sent it");
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);

        _tick(10);
        assertEq(_count(address(watchdog), GAVE_UP_SIG), 1);
        assertFalse(watchdog.ticking());
    }

    function test_WithoutOwnershipItReportsAndNeverReverts() public {
        watchdog.releaseConductor(address(this));
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);

        uint256 revertsBefore = reactionReverts;
        _tick(10);

        assertEq(reactionReverts, revertsBefore);
        assertEq(_count(address(watchdog), REFUSED_SIG), 1);
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
    }

    function test_DisarmedItDoesNothing() public {
        watchdog.setArmed(false);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);

        assertEq(_count(address(watchdog), WATCHING_SIG), 0);
        assertFalse(watchdog.ticking());
        _tick(10);
        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
    }

    function test_DisarmingDropsOpenWatchesAndTheClock() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);
        assertTrue(watchdog.ticking());

        watchdog.setArmed(false);
        _pump();

        assertFalse(watchdog.ticking());
        assertEq(watchdog.openWatches().length, 0);
        uint256 reactionsBefore = reactions;
        _tick(10);
        assertEq(reactions, reactionsBefore);

        // Armed again, the next update is watched as usual.
        watchdog.setArmed(true);
        _chainDown[UNICHAIN_SEPOLIA] = false;
        _publish(MarketTypes.HALTED, 100e18);
        assertTrue(watchdog.ticking());
    }

    function test_AStrayTickAfterTheClockIsOffChangesNothing() public {
        _publish(MarketTypes.OPEN, 100e18);
        _tick(10);
        assertFalse(watchdog.ticking());

        IReactive.LogRecord memory tick = _tickRecord(block.chainid, watchdog.CLOCK());
        vm.recordLogs();
        vm.prank(address(OMNI));
        watchdog.react(tick);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_OnlyTheNetworksClockCounts() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        _publish(MarketTypes.OPEN, 100e18);
        vm.roll(block.number + 20);

        // Right topic, wrong contract; right contract, wrong chain.
        vm.startPrank(address(OMNI));
        watchdog.react(_tickRecord(block.chainid, stranger));
        watchdog.react(_tickRecord(BASE_SEPOLIA, watchdog.CLOCK()));
        vm.stopPrank();
        _pump();

        assertEq(_count(address(watchdog), RETRIED_SIG), 0);
    }

    function test_OnlyTheSystemContractCanCallReact() public {
        IReactive.LogRecord memory tick = _tickRecord(block.chainid, watchdog.CLOCK());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(OMNI)));
        watchdog.react(tick);
    }

    function test_OnlyTheFeedStartsAWatch() public {
        MarketFeed impostor = new MarketFeed();
        impostor.setPublisher(publisher, true);
        _place(address(impostor), BASE_SEPOLIA);

        vm.prank(publisher);
        impostor.publish(NVDA, MarketTypes.OPEN, 1e18, uint64(block.timestamp));
        _pump();

        assertEq(_count(address(watchdog), WATCHING_SIG), 0);
        assertFalse(watchdog.ticking());
    }

    function test_ItStopsTakingNewMarketsWhenFull() public {
        uint256 max = watchdog.MAX_WATCHES();
        _chainDown[UNICHAIN_SEPOLIA] = true;
        for (uint256 i = 0; i != max + 2; ++i) {
            _publish(keccak256(abi.encode("market", i)), MarketTypes.OPEN, 100e18);
        }
        assertEq(watchdog.openWatches().length, max);

        // One tick with every watch re-sending still fits in a reactive transaction.
        _chainDown[UNICHAIN_SEPOLIA] = false;
        vm.roll(block.number + 10);
        IReactive.LogRecord memory tick = _tickRecord(block.chainid, watchdog.CLOCK());
        vm.prank(address(OMNI));
        uint256 gasBefore = gasleft();
        watchdog.react(tick);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 900_000, "a full tick fits under the reactive gas cap");
        _pump();
        assertEq(_count(address(watchdog), RETRIED_SIG), max);
    }

    // ------------------------------------------------------------------------------------------
    // Ownership
    // ------------------------------------------------------------------------------------------

    function test_TheOwnerStillRunsTheConductorThroughTheWatchdog() public {
        BellReactive.Policy[3] memory p = _policy();
        p[MarketTypes.OPEN] = BellReactive.Policy(900, 250);
        watchdog.execute(address(conductor), abi.encodeCall(BellReactive.updateVenue, (0, 400_000, 10, true, p)));

        BellReactive.Venue memory v = conductor.venue(0);
        assertEq(v.gasLimit, 400_000);
        assertEq(v.policy[MarketTypes.OPEN].feePips, 900);
    }

    function test_ExecuteBubblesUpAFailure() public {
        vm.expectRevert();
        watchdog.execute(address(conductor), abi.encodeCall(BellReactive.resync, (NVDA, 99)));
    }

    function test_TheConductorCanBeHandedBack() public {
        watchdog.releaseConductor(address(this));
        assertEq(conductor.owner(), address(this));
        conductor.setPaused(true);
    }

    function test_StrangersCannotTouchTheControls() public {
        vm.startPrank(stranger);
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.execute(address(conductor), "");
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.releaseConductor(stranger);
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.setArmed(false);
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.setTiming(1, 1);
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.transferOwnership(stranger);
        vm.expectRevert(BellWatchdog.NotOwner.selector);
        watchdog.withdraw(payable(stranger), 0);
        vm.stopPrank();
    }

    function test_TimingMustBePositive() public {
        vm.expectRevert(BellWatchdog.BadTiming.selector);
        watchdog.setTiming(0, 3);
        vm.expectRevert(BellWatchdog.BadTiming.selector);
        watchdog.setTiming(8, 0);
        vm.expectRevert(BellWatchdog.BadTiming.selector);
        new BellWatchdog(conductor, 0, 3);
    }

    // ------------------------------------------------------------------------------------------
    // Whatever happens, it ends in sync and switched off
    // ------------------------------------------------------------------------------------------

    function testFuzz_AnyRunOfOutagesEndsInSyncWithTheClockOff(uint256 seed) public {
        uint256 price = 100e18;
        for (uint256 step = 0; step != 24; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _chainDown[UNICHAIN_SEPOLIA] = seed % 3 == 0;
            _chainDown[BASE_SEPOLIA] = (seed >> 8) % 7 == 0;

            if ((seed >> 16) % 2 == 0) {
                price = price * (9_900 + ((seed >> 24) % 200)) / 10_000;
                _publish(uint8((seed >> 40) % 3), price);
            } else {
                _tick(1 + ((seed >> 48) % 12));
            }
        }

        // Both chains come back. A few looks later everything agrees and nothing is being paid for.
        _chainDown[UNICHAIN_SEPOLIA] = false;
        _chainDown[BASE_SEPOLIA] = false;
        uint64 seq = _publish(MarketTypes.OPEN, price + 1e18);
        _tick(10);
        _tick(10);

        assertTrue(conductor.inSync(NVDA));
        (uint8 baseStatus, uint64 baseSeq) = _status(baseGuard);
        (uint8 uniStatus, uint64 uniSeq) = _status(uniGuard);
        assertEq(baseStatus, MarketTypes.OPEN);
        assertEq(uniStatus, MarketTypes.OPEN);
        assertEq(baseSeq, seq);
        assertEq(uniSeq, seq);
        assertFalse(watchdog.ticking());
        assertEq(watchdog.openWatches().length, 0);
        assertEq(reactionReverts, 0);
    }

    function _tickRecord(uint256 chainId, address emitter) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: chainId,
            contractAddress: emitter,
            topic0: watchdog.TICK_TOPIC(),
            topic1: block.number,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }
}
