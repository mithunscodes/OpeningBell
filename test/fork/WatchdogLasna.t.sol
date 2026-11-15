// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MarketTypes } from "../../src/common/MarketTypes.sol";
import { BellReactive } from "../../src/reactive/BellReactive.sol";
import { BellWatchdog } from "../../src/reactive/BellWatchdog.sol";

/// @notice The watchdog against the conductor that is live on Reactive Lasna, on a fork of that
///         network: the real conductor bytecode and state, and the real system contract.
/// @dev    Skipped unless LASNA_RPC is set:
///         LASNA_RPC=https://lasna-rpc.rnk.dev/ forge test --match-contract WatchdogLasnaForkTest -vv
///         The fork plays the network's part by hand: it calls `react()` as the system contract.
contract WatchdogLasnaForkTest is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    BellReactive internal constant CONDUCTOR = BellReactive(payable(0x8ddc373617e2D83348fE72eAcF8C4ffB58e9C46E));
    bytes32 internal constant NVDA = keccak256("NVDA/USD");

    bytes32 internal constant CALLBACK_REQUEST_SIG = keccak256("CallbackRequest(uint256,address,address,uint8,bytes)");
    bytes32 internal constant SUBSCRIBE_SIG =
        keccak256("Subscribe(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant UNSUBSCRIBE_SIG =
        keccak256("Unsubscribe(address,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant RETRIED_SIG = keccak256("Retried(bytes32,uint64,uint256,uint8)");
    bytes32 internal constant SETTLED_SIG = keccak256("Settled(bytes32,uint64,uint8)");

    BellWatchdog internal watchdog;
    address internal owner;
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("LASNA_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        live = true;
        vm.createSelectFork(rpc);

        owner = CONDUCTOR.owner();
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        watchdog = new BellWatchdog{ value: 1 ether }(CONDUCTOR, 8, 3);
        CONDUCTOR.transferOwnership(address(watchdog));
        vm.stopPrank();
    }

    function test_RecoversAMissedLoopOnTheLiveConductor() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertEq(watchdog.FEED(), CONDUCTOR.FEED());
        assertEq(watchdog.FEED_CHAIN_ID(), CONDUCTOR.FEED_CHAIN_ID());
        assertTrue(CONDUCTOR.inSync(NVDA), "the live system starts in sync");

        (uint8 status, uint64 seq,, uint112 price) = CONDUCTOR.markets(NVDA);
        uint8 next = status == MarketTypes.HALTED ? MarketTypes.OPEN : MarketTypes.HALTED;
        IReactive.LogRecord memory update = _update(next, price, seq + 1);

        // The feed publishes. Both reactive contracts hear it; neither venue ever confirms.
        vm.recordLogs();
        vm.startPrank(SYSTEM);
        CONDUCTOR.react(update);
        watchdog.react(update);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, SYSTEM, CALLBACK_REQUEST_SIG), 2, "the conductor sent to both venues");
        assertEq(_count(logs, SYSTEM, SUBSCRIBE_SIG), 1, "the watchdog switched the clock on");
        assertFalse(CONDUCTOR.inSync(NVDA));
        assertTrue(watchdog.ticking());

        // Ten blocks later the clock rings and the watchdog has the conductor send again.
        vm.roll(block.number + 10);
        IReactive.LogRecord memory tick = _tick();
        vm.prank(SYSTEM);
        watchdog.react(tick);

        logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(watchdog), RETRIED_SIG), 2);
        uint256 resent;
        for (uint256 i = 0; i != logs.length; ++i) {
            if (logs[i].emitter != SYSTEM || logs[i].topics[0] != CALLBACK_REQUEST_SIG) continue;
            // The request names the conductor as its sender, which is what the guards check.
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(CONDUCTOR));
            ++resent;
        }
        assertEq(resent, 2, "both venues were sent the state again");

        // The venues confirm this time.
        uint256 venues = CONDUCTOR.venueCount();
        vm.startPrank(SYSTEM);
        for (uint256 v = 0; v != venues; ++v) {
            BellReactive.Venue memory venue = CONDUCTOR.venue(v);
            CONDUCTOR.react(_ack(venue.chainId, venue.guard, seq + 1, next));
        }
        vm.stopPrank();
        assertTrue(CONDUCTOR.inSync(NVDA));

        vm.roll(block.number + 10);
        tick = _tick();
        vm.prank(SYSTEM);
        watchdog.react(tick);

        logs = vm.getRecordedLogs();
        assertEq(_count(logs, address(watchdog), SETTLED_SIG), 1);
        assertEq(_count(logs, SYSTEM, UNSUBSCRIBE_SIG), 1, "the watchdog switched the clock off");
        assertFalse(watchdog.ticking());
    }

    function test_TheOwnerKeepsControlAndCanTakeTheConductorBack() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        vm.startPrank(owner);
        watchdog.execute(address(CONDUCTOR), abi.encodeCall(BellReactive.setPaused, (true)));
        assertTrue(CONDUCTOR.paused());
        watchdog.execute(address(CONDUCTOR), abi.encodeCall(BellReactive.setPaused, (false)));

        uint256 before = owner.balance;
        watchdog.execute(address(CONDUCTOR), abi.encodeCall(BellReactive.withdraw, (payable(owner), 0.01 ether)));
        assertEq(owner.balance - before, 0.01 ether, "the conductor's funds are still reachable");

        watchdog.releaseConductor(owner);
        assertEq(CONDUCTOR.owner(), owner);
        CONDUCTOR.setPaused(false);
        vm.stopPrank();
    }

    function _update(uint8 status, uint256 price, uint64 seq) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: CONDUCTOR.FEED_CHAIN_ID(),
            contractAddress: CONDUCTOR.FEED(),
            topic0: MarketTypes.MARKET_UPDATE_TOPIC,
            topic1: uint256(NVDA),
            topic2: status,
            topic3: 0,
            data: abi.encode(price, uint256(seq), block.timestamp),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 1,
            logIndex: 0
        });
    }

    function _ack(uint256 chainId, address guard, uint64 seq, uint8 status)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId,
            contractAddress: guard,
            topic0: MarketTypes.ACK_TOPIC,
            topic1: uint256(NVDA),
            topic2: seq,
            topic3: 0,
            data: abi.encode(uint256(status)),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 2,
            logIndex: 0
        });
    }

    function _tick() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: block.chainid,
            contractAddress: watchdog.CLOCK(),
            topic0: watchdog.TICK_TOPIC(),
            topic1: block.number,
            topic2: 0,
            topic3: 0,
            data: "",
            blockNumber: block.number,
            opCode: 2,
            blockHash: 0,
            txHash: 3,
            logIndex: 0
        });
    }

    function _count(Vm.Log[] memory logs, address emitter, bytes32 sig) internal pure returns (uint256 n) {
        for (uint256 i = 0; i != logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == sig) ++n;
        }
    }
}
