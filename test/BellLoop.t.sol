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

        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.addVenue(0, stranger, 300_000, 0, _policy());

        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.updateVenue(2, 300_000, 0, true, _policy());

        vm.expectRevert(BellReactive.GasLimitTooLow.selector);
        conductor.updateVenue(0, 99_999, 0, true, _policy());

        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.resync(NVDA, 2);

        vm.expectRevert(BellReactive.UnknownMarket.selector);
        conductor.resync(NVDA, 0);

        // Room for eight venues, no more.
        for (uint256 i = conductor.venueCount(); i != conductor.MAX_VENUES(); ++i) {
            conductor.addVenue(BASE_SEPOLIA, address(uint160(0xA000 + i)), 300_000, 0, _policy());
        }
        vm.expectRevert(BellReactive.TooManyVenues.selector);
        conductor.addVenue(BASE_SEPOLIA, address(0xB000), 300_000, 0, _policy());
    }

    function test_VenuesCanBeLookedUpByAddress() public view {
        (bool found, uint256 venueId) = conductor.venueIdOf(UNICHAIN_SEPOLIA, address(uniGuard));
        assertTrue(found);
        assertEq(venueId, 1);

        (found, venueId) = conductor.venueIdOf(UNICHAIN_SEPOLIA, address(baseGuard));
        assertFalse(found, "right guard, wrong chain");
        assertEq(venueId, 0);
    }

    function _ack(BellGuard guard, uint256 chainId, uint256 seq, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId,
            contractAddress: address(guard),
            topic0: MarketTypes.ACK_TOPIC,
            topic1: uint256(NVDA),
            topic2: seq,
            topic3: 0,
            data: data,
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 2,
            logIndex: 0
        });
    }

    function test_MalformedStaleAndStrayConfirmationsAreIgnored() public {
        uint64 seq = _publish(MarketTypes.OPEN, 140e18);
        assertTrue(conductor.inSync(NVDA));
        uint256 before = _count(address(conductor), IGNORED_SIG);
        bytes memory ok = abi.encode(uint256(MarketTypes.OPEN));

        vm.startPrank(address(OMNI));
        conductor.react(_ack(baseGuard, BASE_SEPOLIA, seq, hex"01")); // wrong data size
        conductor.react(_ack(baseGuard, BASE_SEPOLIA, uint256(type(uint64).max) + 1, ok)); // seq out of range
        conductor.react(_ack(baseGuard, BASE_SEPOLIA, seq, ok)); // already confirmed
        conductor.react(_ack(baseGuard, BASE_SEPOLIA, seq + 5, ok)); // never sent
        conductor.react(_ack(baseGuard, UNICHAIN_SEPOLIA, seq, ok)); // not a venue on that chain
        vm.stopPrank();
        _pump();

        assertEq(_count(address(conductor), IGNORED_SIG) - before, 5, "every bad confirmation is reported");
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 1, "and none of them closes a loop again");
        assertTrue(conductor.inSync(NVDA));
    }

    function test_AnOlderConfirmationDoesNotSettleANewerSend() public {
        // Unichain is down for two updates, so neither is confirmed.
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 first = _publish(MarketTypes.OPEN, 140e18);
        uint64 second = _publish(MarketTypes.HALTED, 140e18);
        (uint64 sentSeq, uint64 ackedSeq,, bool awaiting,) = conductor.links(NVDA, 1);
        assertEq(sentSeq, second);
        assertEq(ackedSeq, 0);
        assertTrue(awaiting);

        // A late confirmation of the first update is recorded, but the venue still owes the second.
        vm.prank(address(OMNI));
        conductor.react(_ack(uniGuard, UNICHAIN_SEPOLIA, first, abi.encode(uint256(MarketTypes.OPEN))));
        _pump();

        (, ackedSeq,, awaiting,) = conductor.links(NVDA, 1);
        assertEq(ackedSeq, first);
        assertTrue(awaiting, "still waiting for the newest state");
        assertFalse(conductor.inSync(NVDA));
    }

    function test_OwnerMovesFundsAndAnyoneCanSettleDebt() public {
        vm.deal(address(conductor), 2 ether);
        vm.deal(address(baseGuard), 1 ether);
        address payable to = payable(makeAddr("treasury"));

        conductor.withdraw(to, 0.5 ether);
        baseGuard.withdraw(to, 0.25 ether);
        assertEq(to.balance, 0.75 ether);

        vm.expectRevert("withdraw failed");
        conductor.withdraw(payable(address(feed)), 1); // the feed takes no ether
        vm.expectRevert("withdraw failed");
        baseGuard.withdraw(payable(address(feed)), 1);

        vm.startPrank(stranger);
        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.withdraw(payable(stranger), 1);
        vm.expectRevert(BellGuard.NotOwner.selector);
        baseGuard.withdraw(payable(stranger), 1);

        // Nothing is owed here, so settling is free and changes nothing.
        conductor.coverDebt();
        baseGuard.coverDebt();
        vm.stopPrank();
        assertEq(address(conductor).balance, 1.5 ether);
        assertEq(address(baseGuard).balance, 0.75 ether);
    }

    function test_OwnershipCanMove() public {
        vm.prank(stranger);
        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.transferOwnership(stranger);
        vm.prank(stranger);
        vm.expectRevert(BellGuard.NotOwner.selector);
        baseGuard.transferOwnership(stranger);

        conductor.transferOwnership(stranger);
        baseGuard.transferOwnership(stranger);
        assertEq(conductor.owner(), stranger);
        assertEq(baseGuard.owner(), stranger);

        vm.expectRevert(BellReactive.NotOwner.selector);
        conductor.setPaused(true);
        vm.expectRevert(BellGuard.NotOwner.selector);
        baseGuard.setListener(NVDA, address(this));
    }

    function test_TheGuardReportsThePriceItHolds() public {
        _publish(MarketTypes.OPEN, 141.5e18);
        assertEq(baseGuard.priceOf(NVDA), 141.5e18);
        assertEq(uniGuard.priceOf(keccak256("TSLA/USD")), 0, "nothing known about another market");
    }

    // ---------------------------------------------------------------------------------------------
    // Records and announcements (added after mutation testing found them unchecked)
    // ---------------------------------------------------------------------------------------------

    function test_TheConductorAnnouncesItsSetUp() public {
        vm.expectEmit(true, true, false, false);
        emit BellReactive.OwnershipTransferred(address(0), address(this));
        vm.expectEmit(false, false, false, true);
        emit BellReactive.AckModeSet(BellReactive.AckMode.OnStatusChange);
        new BellReactive(BASE_SEPOLIA, address(feed), BellReactive.AckMode.OnStatusChange);
    }

    function test_AGoodUpdateIsNeverAlsoReportedAsIgnored() public {
        vm.warp(1_800_000_000);
        uint256 before = _count(address(conductor), IGNORED_SIG);
        _publish(MarketTypes.OPEN, 140e18); // AckMode.Always: both confirmations come back too
        assertEq(_count(address(conductor), IGNORED_SIG), before, "neither the update nor its confirmations");
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 1);
        assertEq(_count(address(conductor), FORWARDED_SIG), 2, "one send per venue");
        assertEq(_count(address(conductor), keccak256("VenueAcked(bytes32,uint64,uint256,uint8)")), 2, "one per venue");

        (,, uint64 sourceTime,) = conductor.markets(NVDA);
        assertEq(sourceTime, 1_800_000_000, "the time at the source is kept");
    }

    function test_IgnoredLogsSayWhy() public {
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);
        uint256 malformed = conductor.IGNORED_MALFORMED();
        uint256 stale = conductor.IGNORED_STALE();

        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: MarketTypes.MARKET_UPDATE_TOPIC,
            topic1: uint256(NVDA),
            topic2: 7, // not a status
            topic3: 0,
            data: abi.encode(uint256(100e18), uint64(seq + 1), uint64(1)),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 42,
            logIndex: 0
        });
        vm.startPrank(address(OMNI));

        vm.expectEmit(true, false, false, true, address(conductor));
        emit BellReactive.Ignored(malformed, BASE_SEPOLIA, address(feed), 42);
        conductor.react(log_);

        log_.topic2 = MarketTypes.OPEN;
        log_.data = abi.encode(uint256(0), uint64(seq + 1), uint64(1)); // zero price
        vm.expectEmit(true, false, false, true, address(conductor));
        emit BellReactive.Ignored(malformed, BASE_SEPOLIA, address(feed), 42);
        conductor.react(log_);

        log_.data = abi.encode(uint256(100e18), uint64(seq), uint64(1)); // already seen
        vm.expectEmit(true, false, false, true, address(conductor));
        emit BellReactive.Ignored(stale, BASE_SEPOLIA, address(feed), 42);
        conductor.react(log_);
        vm.stopPrank();
    }

    function test_TheGuardRecordsWhenItAppliedAndAnnouncesWhatItIgnored() public {
        vm.expectEmit(true, false, false, true, address(baseGuard));
        emit BellGuard.ListenerSet(NVDA, address(0xBEEF));
        baseGuard.setListener(NVDA, address(0xBEEF));
        assertEq(baseGuard.listeners(NVDA), address(0xBEEF));
        baseGuard.setListener(NVDA, address(0));

        vm.warp(1_800_000_000);
        _publish(MarketTypes.OPEN, 100e18);
        vm.warp(1_800_000_060);
        uint64 seq = _publish(MarketTypes.HALTED, 100e18);
        (,,,,, uint64 appliedAt) = baseGuard.current(NVDA);
        assertEq(appliedAt, 1_800_000_060);

        vm.expectEmit(true, false, false, true, address(baseGuard));
        emit BellGuard.Stale(NVDA, 1, seq);
        vm.prank(address(_proxy(BASE_SEPOLIA)));
        baseGuard.applyState(address(conductor), NVDA, 1, MarketTypes.OPEN, 100e18, OPEN_FEE, OPEN_RANGE, true, 0, 0);
    }

    function test_AListenerWithoutGasDoesNotStopTheStateLanding() public {
        bytes memory payload = abi.encodeCall(
            BellGuard.applyState,
            (
                address(conductor),
                NVDA,
                uint64(1),
                MarketTypes.HALTED,
                uint256(100e18),
                uint24(0),
                uint24(0),
                false,
                0,
                0
            )
        );
        address proxy = address(_proxy(BASE_SEPOLIA));

        // The gas it takes to apply the state when there is no listener.
        uint256 snap = vm.snapshotState();
        vm.prank(proxy);
        uint256 before = gasleft();
        (bool ok,) = address(baseGuard).call(payload);
        uint256 needed = before - gasleft();
        assertTrue(ok);
        vm.revertToState(snap);

        // With a listener and only 30,000 gas to spare, less than the guard keeps back for itself, the
        // listener gets nothing and fails, and the state still lands.
        baseGuard.setListener(NVDA, address(new RecordingListener()));
        vm.prank(proxy);
        (ok,) = address(baseGuard).call{ gas: needed + 30_000 }(payload);
        assertTrue(ok, "the callback did not revert");
        _assertGuard(baseGuard, MarketTypes.HALTED, 100e18, 0, 0, 1);
    }

    function test_SettlingDebtPaysWhatIsOwed() public {
        vm.deal(address(conductor), 1 ether);
        vm.deal(address(baseGuard), 1 ether);
        address proxy = address(_proxy(BASE_SEPOLIA));
        vm.mockCall(address(OMNI), abi.encodeWithSignature("debt(address)", address(conductor)), abi.encode(0.1 ether));
        vm.mockCall(proxy, abi.encodeWithSignature("debt(address)", address(baseGuard)), abi.encode(0.2 ether));

        vm.startPrank(stranger);
        conductor.coverDebt();
        baseGuard.coverDebt();
        vm.stopPrank();

        assertEq(address(conductor).balance, 0.9 ether);
        assertEq(address(baseGuard).balance, 0.8 ether);
    }

    function test_OwnerChangesAreAnnouncedAndTakeEffect() public {
        BellReactive.Policy[3] memory p = _policy();
        p[MarketTypes.CLOSED] = BellReactive.Policy(10_000, 2_000);

        vm.expectEmit(true, true, true, false, address(conductor));
        emit BellReactive.VenueAdded(2, UNICHAIN_SEPOLIA, stranger);
        conductor.addVenue(UNICHAIN_SEPOLIA, stranger, conductor.MIN_CALLBACK_GAS(), 0, _policy());
        conductor.updateVenue(2, conductor.MIN_CALLBACK_GAS(), 0, false, _policy()); // the minimum is allowed

        vm.expectEmit(true, false, false, false, address(conductor));
        emit BellReactive.VenueUpdated(0);
        conductor.updateVenue(0, 300_000, 0, true, p);
        BellReactive.Venue memory v = conductor.venue(0);
        assertEq(v.minMoveBps, 0, "the new minimum move");
        assertEq(v.policy[MarketTypes.CLOSED].feePips, 10_000, "every status's policy is replaced, CLOSED too");

        // With no minimum move, even a tiny price change is sent to venue 0.
        _publish(MarketTypes.CLOSED, 100e18);
        _publish(MarketTypes.CLOSED, 100.01e18);
        _assertGuard(baseGuard, MarketTypes.CLOSED, 100.01e18, 10_000, 2_000, 2);
        _assertGuard(uniGuard, MarketTypes.CLOSED, 100e18, CLOSED_FEE, CLOSED_RANGE, 1);

        vm.expectEmit(false, false, false, true, address(conductor));
        emit BellReactive.AckModeSet(BellReactive.AckMode.Never);
        conductor.setAckMode(BellReactive.AckMode.Never);
        vm.expectEmit(false, false, false, true, address(conductor));
        emit BellReactive.PausedSet(true);
        conductor.setPaused(true);
        vm.expectEmit(true, true, false, false, address(conductor));
        emit BellReactive.OwnershipTransferred(address(this), stranger);
        conductor.transferOwnership(stranger);
    }

    function test_UnknownVenueNumbersAreRefusedCleanly() public {
        _publish(MarketTypes.OPEN, 100e18);
        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.updateVenue(7, 300_000, 0, true, _policy());
        vm.expectRevert(BellReactive.BadVenue.selector);
        conductor.resync(NVDA, 7);
    }

    function _feedLog(uint256 topic0, uint8 status, bytes memory data)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: topic0,
            topic1: uint256(NVDA),
            topic2: status,
            topic3: 0,
            data: data,
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: 42,
            logIndex: 0
        });
    }

    function _expectIgnored(uint256 reason, IReactive.LogRecord memory log_) internal {
        vm.expectEmit(true, false, false, true, address(conductor));
        emit BellReactive.Ignored(reason, log_.chainId, log_.contractAddress, log_.txHash);
        vm.prank(address(OMNI));
        conductor.react(log_);
    }

    function test_OnlyExactlyTheRightLogsAreActedOn() public {
        uint64 seq = _publish(MarketTypes.OPEN, 100e18);
        uint256 unknown = conductor.IGNORED_UNKNOWN_SOURCE();
        uint256 malformed = conductor.IGNORED_MALFORMED();
        uint256 stale = conductor.IGNORED_STALE();
        bytes memory next = abi.encode(uint256(90e18), uint64(seq + 1), uint64(1));

        // Another event of the feed, whatever its topic, is not a market update.
        _expectIgnored(unknown, _feedLog(MarketTypes.MARKET_UPDATE_TOPIC + 1, MarketTypes.OPEN, next));
        _expectIgnored(unknown, _feedLog(MarketTypes.MARKET_UPDATE_TOPIC - 1, MarketTypes.OPEN, next));
        // Another event of a guard is not a confirmation.
        IReactive.LogRecord memory fromGuard = _ack(baseGuard, BASE_SEPOLIA, seq, abi.encode(uint256(MarketTypes.OPEN)));
        fromGuard.topic0 = MarketTypes.ACK_TOPIC + 1;
        _expectIgnored(unknown, fromGuard);
        fromGuard.topic0 = MarketTypes.ACK_TOPIC - 1;
        _expectIgnored(unknown, fromGuard);
        fromGuard.topic0 = uint256(APPLIED_SIG);
        _expectIgnored(unknown, fromGuard);

        // A market update must be exactly three words long.
        _expectIgnored(
            malformed, _feedLog(MarketTypes.MARKET_UPDATE_TOPIC, MarketTypes.OPEN, bytes.concat(next, bytes32(0)))
        );
        // The same observation twice is stale the second time.
        _expectIgnored(
            stale,
            _feedLog(MarketTypes.MARKET_UPDATE_TOPIC, MarketTypes.OPEN, abi.encode(uint256(90e18), seq, uint64(1)))
        );

        // A confirmation must be exactly one word long and carry a sequence number that fits.
        bytes memory ok = abi.encode(uint256(MarketTypes.OPEN));
        _expectIgnored(malformed, _ack(baseGuard, BASE_SEPOLIA, seq, hex"01"));
        _expectIgnored(malformed, _ack(baseGuard, BASE_SEPOLIA, seq, bytes.concat(ok, ok)));
        _expectIgnored(malformed, _ack(baseGuard, BASE_SEPOLIA, uint256(type(uint64).max) + 1, ok));
        _expectIgnored(stale, _ack(baseGuard, BASE_SEPOLIA, type(uint64).max, ok)); // fits, but never sent

        (, uint64 known,,) = conductor.markets(NVDA);
        assertEq(known, seq, "none of them was taken as an update");
        assertEq(_count(address(conductor), FORWARDED_SIG), 2, "and nothing more was sent");
    }

    function test_SequenceNumbersBeyondThirtyTwoBitsWork() public {
        uint64 big = uint64(1) << 40;
        IReactive.LogRecord memory log_ =
            _feedLog(MarketTypes.MARKET_UPDATE_TOPIC, MarketTypes.OPEN, abi.encode(uint256(100e18), big, uint64(1)));
        vm.expectEmit(true, true, false, true, address(conductor));
        emit BellReactive.Observed(NVDA, big, MarketTypes.OPEN, 100e18, log_.blockNumber, 42);
        vm.prank(address(OMNI));
        conductor.react(log_);
        _pump();

        (, uint64 seq,,) = conductor.markets(NVDA);
        assertEq(seq, big);
        _assertGuard(baseGuard, MarketTypes.OPEN, 100e18, OPEN_FEE, OPEN_RANGE, big);
        (, uint64 acked,,,) = conductor.links(NVDA, 1);
        assertEq(acked, big, "the confirmation of a large sequence number counts");
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), 1);
    }

    function test_AnOlderConfirmationNeverWindsTheRecordBack() public {
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 first = _publish(MarketTypes.OPEN, 140e18);
        uint64 second = _publish(MarketTypes.HALTED, 140e18);
        bytes memory halted = abi.encode(uint256(MarketTypes.HALTED));

        vm.startPrank(address(OMNI));
        conductor.react(_ack(uniGuard, UNICHAIN_SEPOLIA, second, halted));
        vm.stopPrank();
        _expectIgnored(
            conductor.IGNORED_STALE(), _ack(uniGuard, UNICHAIN_SEPOLIA, first, abi.encode(uint256(MarketTypes.OPEN)))
        );

        (, uint64 acked,,,) = conductor.links(NVDA, 1);
        assertEq(acked, second);
        assertTrue(conductor.inSync(NVDA));
    }

    function test_TheLoopClosesOnlyWithTheLastConfirmation() public {
        // Whichever venue confirms last, the loop closes then and not before.
        for (uint256 late = 0; late != 2; ++late) {
            (BellGuard lateGuard, uint256 lateChain) =
                late == 0 ? (baseGuard, BASE_SEPOLIA) : (uniGuard, UNICHAIN_SEPOLIA);
            _chainDown[lateChain] = true;
            uint64 seq = _publish(late == 0 ? MarketTypes.OPEN : MarketTypes.HALTED, 100e18);
            uint256 closedBefore = _count(address(conductor), LOOP_CLOSED_SIG);
            _chainDown[lateChain] = false;

            assertEq(_count(address(conductor), LOOP_CLOSED_SIG), closedBefore, "one venue still owes");
            assertFalse(conductor.inSync(NVDA));

            (uint8 status,,,) = conductor.markets(NVDA);
            vm.prank(address(OMNI));
            conductor.react(_ack(lateGuard, lateChain, seq, abi.encode(uint256(status))));
            _pump();
            assertEq(_count(address(conductor), LOOP_CLOSED_SIG), closedBefore + 1, "closed by the last one");
        }
    }

    function test_AVenueThatWasNeverToldKeepsTheLoopOpen() public {
        // A third venue, switched off before the first update and back on before the last confirmation.
        BellGuard third = new BellGuard(IPayable(payable(address(_proxy(BASE_SEPOLIA)))), address(conductor));
        _place(address(third), BASE_SEPOLIA);
        conductor.addVenue(BASE_SEPOLIA, address(third), 300_000, 10, _policy());

        // Never sent anything (sentSeq 0), on a CLOSED market (status 0, the zero value).
        _thirdOff(2);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        uint64 seq = _publish(MarketTypes.CLOSED, 100e18);
        _assertLoopStaysOpenWhenThirdReturns(seq, MarketTypes.CLOSED);

        // Sent OPEN, then the market halts while it is off: it holds a lower status than the market's.
        _resetLoop(MarketTypes.OPEN);
        _thirdOff(2);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        seq = _publish(MarketTypes.HALTED, 100e18);
        _assertLoopStaysOpenWhenThirdReturns(seq, MarketTypes.HALTED);

        // Sent HALTED, then the market closes while it is off: it holds a higher status.
        _resetLoop(MarketTypes.HALTED);
        _thirdOff(2);
        _chainDown[UNICHAIN_SEPOLIA] = true;
        seq = _publish(MarketTypes.CLOSED, 100e18);
        _assertLoopStaysOpenWhenThirdReturns(seq, MarketTypes.CLOSED);
    }

    function _thirdOff(uint256 venueId) internal {
        conductor.updateVenue(venueId, 300_000, 10, false, _policy());
    }

    function _resetLoop(uint8 status) internal {
        conductor.updateVenue(2, 300_000, 10, true, _policy());
        _publish(status, 100e18);
        assertTrue(conductor.inSync(NVDA), "all three in step");
    }

    function _assertLoopStaysOpenWhenThirdReturns(uint64 seq, uint8 status) internal {
        _chainDown[UNICHAIN_SEPOLIA] = false;
        conductor.updateVenue(2, 300_000, 10, true, _policy()); // back on, but never told about `seq`
        uint256 closedBefore = _count(address(conductor), LOOP_CLOSED_SIG);
        vm.prank(address(OMNI));
        conductor.react(_ack(uniGuard, UNICHAIN_SEPOLIA, seq, abi.encode(uint256(status))));
        _pump();
        assertEq(_count(address(conductor), LOOP_CLOSED_SIG), closedBefore, "the third venue is behind");
        assertFalse(conductor.inSync(NVDA));
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
