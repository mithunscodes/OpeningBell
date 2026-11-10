// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { OmniTest } from "./harness/OmniTest.sol";
import { MarketTypes } from "../src/common/MarketTypes.sol";
import { MarketFeed } from "../src/origin/MarketFeed.sol";
import { BellReactive } from "../src/reactive/BellReactive.sol";
import { BellGuard, IMarketListener } from "../src/venue/BellGuard.sol";

contract RecordingListener is IMarketListener {
    uint256 public calls;
    uint8 public lastStatus;
    uint256 public lastPrice;
    bool public broken;
    bool public greedy;

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function setGreedy(bool greedy_) external {
        greedy = greedy_;
    }

    function onMarketState(bytes32, uint8 status, uint256 price, uint24, uint24) external {
        if (broken) revert("listener is broken");
        if (greedy) {
            // Burn everything that was handed over.
            uint256 x;
            while (true) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        ++calls;
        lastStatus = status;
        lastPrice = price;
    }
}

/// @notice The full loop with no pools attached: feed on Base, conductor on Reactive, guards on
///         Base and Unichain.
contract BellLoopTest is OmniTest {
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    bytes32 internal constant APPLIED_SIG =
        keccak256("Applied(bytes32,uint64,uint8,uint256,uint24,uint24,uint256,uint256)");
    bytes32 internal constant ACK_SIG = keccak256("Ack(bytes32,uint64,uint8)");
    bytes32 internal constant STALE_SIG = keccak256("Stale(bytes32,uint64,uint64)");
    bytes32 internal constant FORWARDED_SIG =
        keccak256("Forwarded(bytes32,uint64,uint256,uint8,uint256,uint24,uint24,bool)");
    bytes32 internal constant FILTERED_SIG = keccak256("Filtered(bytes32,uint64,uint256)");
    bytes32 internal constant LOOP_CLOSED_SIG = keccak256("LoopClosed(bytes32,uint64)");
    bytes32 internal constant IGNORED_SIG = keccak256("Ignored(uint256,uint256,address,uint256)");
    bytes32 internal constant LISTENER_FAILED_SIG = keccak256("ListenerFailed(bytes32,address,bytes)");

    uint24 internal constant OPEN_FEE = 500; // 0.05%
    uint24 internal constant CLOSED_FEE = 30_000; // 3%
    uint24 internal constant OPEN_RANGE = 100; // +-1%
    uint24 internal constant CLOSED_RANGE = 1_500; // +-15%

    address internal publisher = makeAddr("publisher");
    address internal stranger = makeAddr("stranger");

    MarketFeed internal feed;
    BellReactive internal conductor;
    BellGuard internal baseGuard;
    BellGuard internal uniGuard;

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

        _pump(); // flush set-up logs
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

    function _assertGuard(BellGuard guard, uint8 status, uint256 price, uint24 fee, uint24 range, uint64 seq)
        internal
        view
    {
        (uint8 s, uint256 p, uint24 f, uint24 r, uint64 q,) = guard.current(NVDA);
        assertEq(s, status, "status");
        assertEq(p, price, "price");
        assertEq(f, fee, "fee");
        assertEq(r, range, "range");
        assertEq(q, seq, "seq");
    }

    // ---------------------------------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------------------------------

    function test_OneFeedEventReachesEveryVenue() public {
        uint64 seq = _publish(MarketTypes.OPEN, 140e18);

        _assertGuard(baseGuard, MarketTypes.OPEN, 140e18, OPEN_FEE, OPEN_RANGE, seq);
        _assertGuard(uniGuard, MarketTypes.OPEN, 140e18, OPEN_FEE, OPEN_RANGE, seq);

        // One reaction for the feed event, one per confirmation.
        assertEq(reactions, 3, "reactions");
        assertEq(deliveries, 2, "deliveries");
        assertEq(reactionReverts + deliveryFailures, 0, "failures");
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 1, "loop closed once");
        assertTrue(conductor.inSync(NVDA));
    }

    function test_PolicyFollowsMarketStatus() public {
        _publish(MarketTypes.OPEN, 140e18);

        uint64 seq = _publish(MarketTypes.HALTED, 140e18);
        _assertGuard(baseGuard, MarketTypes.HALTED, 140e18, 0, 0, seq);
        _assertGuard(uniGuard, MarketTypes.HALTED, 140e18, 0, 0, seq);

        seq = _publish(MarketTypes.OPEN, 126e18);
        _assertGuard(baseGuard, MarketTypes.OPEN, 126e18, OPEN_FEE, OPEN_RANGE, seq);

        seq = _publish(MarketTypes.CLOSED, 127e18);
        _assertGuard(uniGuard, MarketTypes.CLOSED, 127e18, CLOSED_FEE, CLOSED_RANGE, seq);
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 4);
    }

    function test_AppliedLogLinksBackToTheFeedEvent() public {
        _publish(MarketTypes.OPEN, 140e18);

        Vm.Log memory observed =
            _last(address(conductor), keccak256("Observed(bytes32,uint64,uint8,uint256,uint256,uint256)"));
        (,, uint256 originBlock, uint256 originTx) = abi.decode(observed.data, (uint8, uint256, uint256, uint256));

        Vm.Log memory applied = _last(address(uniGuard), APPLIED_SIG);
        (,,,, uint256 guardOriginBlock, uint256 guardOriginTx) =
            abi.decode(applied.data, (uint8, uint256, uint24, uint24, uint256, uint256));

        assertEq(guardOriginBlock, originBlock);
        assertEq(guardOriginTx, originTx);
        assertTrue(originTx != 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Filtering
    // ---------------------------------------------------------------------------------------------

    function test_SmallPriceMovesAreNotForwarded() public {
        uint64 first = _publish(MarketTypes.OPEN, 100e18);
        uint256 deliveriesBefore = deliveries;

        // 5 bps move, below the 10 bps threshold.
        _publish(MarketTypes.OPEN, 100.05e18);

        assertEq(deliveries, deliveriesBefore, "no callback for a small move");
        assertEq(_count(address(conductor), FILTERED_SIG), 2);
        _assertGuard(baseGuard, MarketTypes.OPEN, 100e18, OPEN_FEE, OPEN_RANGE, first);
        assertTrue(conductor.inSync(NVDA), "a filtered venue still counts as in sync");
    }

    function test_MovesAreMeasuredFromTheLastPriceSent() public {
        _publish(MarketTypes.OPEN, 100e18);
        _publish(MarketTypes.OPEN, 100.06e18); // filtered
        uint64 seq = _publish(MarketTypes.OPEN, 100.11e18); // 11 bps from the last price sent

        _assertGuard(baseGuard, MarketTypes.OPEN, 100.11e18, OPEN_FEE, OPEN_RANGE, seq);
    }

    function test_StatusChangeIsForwardedEvenWithoutAPriceMove() public {
        _publish(MarketTypes.OPEN, 100e18);
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);

        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, seq);
    }

    function testFuzz_FilterThreshold(uint256 start, uint256 next) public {
        start = bound(start, 1e15, 1e24);
        next = bound(next, 1e15, 1e24);

        _publish(MarketTypes.OPEN, start);
        uint256 deliveriesBefore = deliveries;
        _publish(MarketTypes.OPEN, next);

        uint256 diff = start > next ? start - next : next - start;
        bool expected = diff * 10_000 >= start * 10;
        assertEq(deliveries - deliveriesBefore, expected ? 2 : 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Things going wrong
    // ---------------------------------------------------------------------------------------------

    function test_AVenueThatMissedACallbackIsCaughtUpOnTheNextUpdate() public {
        _publish(MarketTypes.OPEN, 100e18);

        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 halted = _publish(MarketTypes.HALTED, 100e18);

        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, halted);
        (uint8 uniStatus,,,,,) = uniGuard.current(NVDA);
        assertEq(uniStatus, MarketTypes.OPEN, "Unichain missed the halt");
        assertFalse(conductor.inSync(NVDA));

        // Same status, no price move: normally filtered. Unichain still owes a confirmation, so it is sent anyway.
        _chainDown[UNICHAIN_SEPOLIA] = false;
        uint256 deliveriesBefore = deliveries;
        uint64 next = _publish(MarketTypes.HALTED, 100e18);

        assertEq(deliveries - deliveriesBefore, 1, "only the lagging venue gets a callback");
        _assertGuard(uniGuard, MarketTypes.HALTED, 100e18, 0, 0, next);
        assertTrue(conductor.inSync(NVDA));
    }

    function test_OwnerCanResyncAVenue() public {
        _publish(MarketTypes.OPEN, 100e18);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(MarketTypes.CLOSED, 101e18);
        _chainDown[UNICHAIN_SEPOLIA] = false;

        conductor.resync(NVDA, 1);
        _pump();

        _assertGuard(uniGuard, MarketTypes.CLOSED, 101e18, CLOSED_FEE, CLOSED_RANGE, seq);
        assertTrue(conductor.inSync(NVDA));
    }

    function test_ResyncAppliesAChangedPolicyAtTheSameSequence() public {
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);

        BellReactive.Policy[3] memory p = _policy();
        p[MarketTypes.OPEN] = BellReactive.Policy(900, 250);
        conductor.updateVenue(0, 300_000, 10, true, p);
        conductor.resync(NVDA, 0);
        _pump();

        _assertGuard(baseGuard, MarketTypes.OPEN, 100e18, 900, 250, seq);
    }

    function test_OutOfOrderFeedLogsAreIgnored() public {
        _publish(MarketTypes.OPEN, 100e18);
        _publish(MarketTypes.HALTED, 100e18);

        // Replay the first observation by hand, as the system contract.
        IReactive.LogRecord memory replay = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: MarketTypes.MARKET_UPDATE_TOPIC,
            topic1: uint256(NVDA),
            topic2: MarketTypes.OPEN,
            topic3: 0,
            data: abi.encode(uint256(100e18), uint64(1), uint64(block.timestamp)),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 1,
            logIndex: 0
        });
        vm.prank(address(OMNI));
        conductor.react(replay);
        _pump();

        (uint8 status,,,) = conductor.markets(NVDA);
        assertEq(status, MarketTypes.HALTED);
        (uint8 guardStatus,,,,,) = baseGuard.current(NVDA);
        assertEq(guardStatus, MarketTypes.HALTED);
    }

    function test_OutOfOrderCallbacksAreIgnoredByTheGuard() public {
        _publish(MarketTypes.OPEN, 100e18);
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);

        vm.prank(address(_proxy(BASE_SEPOLIA)));
        baseGuard.applyState(address(conductor), NVDA, 1, MarketTypes.OPEN, 100e18, OPEN_FEE, OPEN_RANGE, true, 0, 0);

        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, seq);
    }

    function test_MalformedFeedLogsNeverRevert() public {
        IReactive.LogRecord memory bad = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: MarketTypes.MARKET_UPDATE_TOPIC,
            topic1: uint256(NVDA),
            topic2: 7, // not a status
            topic3: 0,
            data: hex"1234",
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 1,
            logIndex: 0
        });
        vm.startPrank(address(OMNI));
        conductor.react(bad);

        bad.topic2 = MarketTypes.OPEN;
        conductor.react(bad);

        bad.data = abi.encode(uint256(0), uint64(9), uint64(1)); // zero price
        conductor.react(bad);

        bad.data = abi.encode(type(uint256).max, uint64(9), uint64(1)); // absurd price
        conductor.react(bad);

        bad.contractAddress = stranger; // somebody else's feed
        bad.data = abi.encode(uint256(1e18), uint64(9), uint64(1));
        conductor.react(bad);
        vm.stopPrank();

        (, uint64 seq,,) = conductor.markets(NVDA);
        assertEq(seq, 0, "nothing was accepted");
        _pump();
        assertEq(requests, 0, "nothing was forwarded");
    }

    function test_ABrokenListenerDoesNotBlockTheState() public {
        RecordingListener listener = new RecordingListener();
        baseGuard.setListener(NVDA, address(listener));

        _publish(MarketTypes.OPEN, 100e18);
        assertEq(listener.calls(), 1);
        assertEq(listener.lastPrice(), 100e18);

        listener.setBroken(true);
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);

        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, seq);
        assertEq(_count(address(baseGuard), LISTENER_FAILED_SIG), 1);
        assertTrue(conductor.inSync(NVDA), "the guard still confirmed");
    }

    function test_AGasHungryListenerDoesNotBlockTheState() public {
        RecordingListener listener = new RecordingListener();
        baseGuard.setListener(NVDA, address(listener));
        listener.setGreedy(true);

        uint64 seq = _publish(MarketTypes.HALTED, 100e18);

        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, seq);
        assertEq(deliveryFailures, 0, "the callback itself succeeded");
        assertTrue(conductor.inSync(NVDA));
    }

    function test_PausedConductorForwardsNothing() public {
        conductor.setPaused(true);
        _publish(MarketTypes.OPEN, 100e18);

        assertEq(deliveries, 0);
        assertEq(_count(address(conductor), IGNORED_SIG), 1);
    }

    function test_InactiveVenueIsSkipped() public {
        conductor.updateVenue(1, 300_000, 10, false, _policy());
        _publish(MarketTypes.OPEN, 100e18);

        assertEq(deliveries, 1);
        (,,,,, uint64 appliedAt) = uniGuard.current(NVDA);
        assertEq(appliedAt, 0);
        assertTrue(conductor.inSync(NVDA), "inactive venues do not hold the loop open");
    }

    // ---------------------------------------------------------------------------------------------
    // Ack modes
    // ---------------------------------------------------------------------------------------------

    function test_AckModeNeverCostsOneReactionPerUpdate() public {
        conductor.setAckMode(BellReactive.AckMode.Never);
        _publish(MarketTypes.OPEN, 100e18);

        assertEq(reactions, 1);
        assertEq(deliveries, 2);
        assertEq(_count(address(baseGuard), ACK_SIG), 0);
    }

    function test_AckModeOnStatusChangeSkipsConfirmationsForPriceMoves() public {
        conductor.setAckMode(BellReactive.AckMode.OnStatusChange);

        _publish(MarketTypes.OPEN, 100e18);
        assertEq(reactions, 3, "status change: feed + two confirmations");

        _publish(MarketTypes.OPEN, 101e18);
        assertEq(reactions, 4, "price move: feed only");
        assertTrue(conductor.inSync(NVDA));
    }

    // ---------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------

    function test_OnlyTheSystemContractCanCallReact() public {
        IReactive.LogRecord memory record;
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(OMNI)));
        vm.prank(stranger);
        conductor.react(record);
    }

    function test_OnlyTheCallbackProxyCanWriteToTheGuard() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(_proxy(BASE_SEPOLIA)))
        );
        vm.prank(stranger);
        baseGuard.applyState(address(conductor), NVDA, 1, MarketTypes.HALTED, 1e18, 0, 0, false, 0, 0);
    }

    function test_OnlyOurConductorCanDriveTheGuard() public {
        // Another reactive contract goes through the legitimate proxy.
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, address(conductor))
        );
        vm.prank(address(_proxy(BASE_SEPOLIA)));
        baseGuard.applyState(stranger, NVDA, 1, MarketTypes.HALTED, 1e18, 0, 0, false, 0, 0);
    }

    function test_OnlyPublishersCanPublish() public {
        vm.expectRevert(MarketFeed.NotPublisher.selector);
        vm.prank(stranger);
        feed.publish(NVDA, MarketTypes.OPEN, 1e18, 0);
    }

    function test_OwnerOnlyControls() public {
        vm.startPrank(stranger);
        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.addVenue(1, stranger, 300_000, 0, _policy());
        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.resync(NVDA, 0);
        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.setPaused(true);
        vm.expectRevert(BellGuard.NotOwner.selector);
        baseGuard.setListener(NVDA, stranger);
        vm.stopPrank();
    }

    function test_VenueRegistrationRules() public {
        vm.expectRevert(BellReactive.VenueExists.selector);
        conductor.addVenue(BASE_SEPOLIA, address(baseGuard), 300_000, 0, _policy());

        vm.expectRevert(BellReactive.GasLimitTooLow.selector);
        conductor.addVenue(BASE_SEPOLIA, stranger, 99_999, 0, _policy());

        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.addVenue(BASE_SEPOLIA, address(0), 300_000, 0, _policy());
    }

    // ---------------------------------------------------------------------------------------------
    // Randomised sequences
    // ---------------------------------------------------------------------------------------------

    /// @dev Whatever the feed does, a venue's state is always exactly what the conductor last sent it,
    ///      and a venue that is "in sync" holds the market's current status.
    function testFuzz_GuardsAlwaysMatchWhatWasSent(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 24));
        uint256 price = 100e18;

        for (uint256 i = 0; i != steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint8 status = uint8(seed % 3);
            // Moves between -2% and +2%, many of them below the filter threshold.
            price = price * (9_800 + ((seed >> 8) % 401)) / 10_000;
            if (price == 0) price = 1;

            _chainDown[UNICHAIN_SEPOLIA] = (seed >> 32) % 5 == 0;
            _publish(status, price);

            _assertMatchesLink(baseGuard, 0);
            if (!_chainDown[UNICHAIN_SEPOLIA]) _assertMatchesLink(uniGuard, 1);
        }

        _chainDown[UNICHAIN_SEPOLIA] = false;
        (uint8 finalStatus,,,) = conductor.markets(NVDA);
        _publish(finalStatus, price);

        assertTrue(conductor.inSync(NVDA));
        (uint8 a,,,,,) = baseGuard.current(NVDA);
        (uint8 b,,,,,) = uniGuard.current(NVDA);
        assertEq(a, finalStatus);
        assertEq(b, finalStatus);
        assertEq(reactionReverts + deliveryFailures, 0);
    }

    function _assertMatchesLink(BellGuard guard, uint256 venueId) internal view {
        (uint64 sentSeq,, uint8 sentStatus,, uint112 sentPrice) = conductor.links(NVDA, venueId);
        (uint8 status, uint256 price,,, uint64 seq,) = guard.current(NVDA);
        assertEq(seq, sentSeq, "seq");
        assertEq(status, sentStatus, "status");
        assertEq(price, sentPrice, "price");
    }
}
