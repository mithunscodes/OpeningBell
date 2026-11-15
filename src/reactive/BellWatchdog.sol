// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MarketTypes } from "../common/MarketTypes.sol";
import { BellReactive } from "./BellReactive.sol";

/// @title BellWatchdog
/// @notice A second reactive contract that makes sure every loop closes. It hears the same market
///         update the conductor hears, then checks on the conductor a few blocks later. If a venue
///         still owes a confirmation, it has the conductor send that venue the state again. Nobody
///         has to notice the gap or press anything.
/// @dev    Three things only Reactive Network gives it:
///
///         - a clock: the network's own `Cron10` events, one every ten blocks;
///         - subscriptions that change at run time: the watchdog listens to the clock only while a
///           loop is open, so a quiet market costs nothing;
///         - a neighbour to talk to: `react()` is an ordinary transaction, so it reads the
///           conductor's books and calls `resync` on it directly.
///
///         The watchdog has to own the conductor, because `resync` is an owner call. Everything the
///         owner could do before is still reachable through `execute`, and `releaseConductor` hands
///         the conductor back.
///
///         The hot path is untouched: the first callback to each venue still leaves in the
///         conductor's own reactive transaction, with nothing in front of it.
///
///         `react()` never reverts: a reverting reactive transaction is still charged.
contract BellWatchdog is AbstractReactive {
    // ---------------------------------------------------------------------------------------------
    // Types, events, errors
    // ---------------------------------------------------------------------------------------------

    /// @dev One open loop. One storage slot.
    struct Watch {
        /// @dev Newest sequence number the feed published for this market.
        uint64 seq;
        /// @dev Reactive Network block of the update, or of the last re-send.
        uint64 sinceBlock;
        uint8 retries;
        bool open;
    }

    /// @notice A market update was heard and its loop is now being watched.
    event Watching(bytes32 indexed marketId, uint64 indexed seq);

    /// @notice A venue had not confirmed in time, so the conductor was told to send to it again.
    event Retried(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId, uint8 attempt);

    /// @notice The conductor refused a re-send. The watchdog is probably not its owner.
    event RetryRefused(bytes32 indexed marketId, uint256 indexed venueId, bytes reason);

    /// @notice Every venue confirmed. `retries` is how many rounds of re-sends that took.
    event Settled(bytes32 indexed marketId, uint64 indexed seq, uint8 retries);

    /// @notice The loop is still open after the last allowed re-send. A person has to look.
    event GaveUp(bytes32 indexed marketId, uint64 indexed seq, uint8 retries);

    /// @notice The clock subscription was switched on or off.
    event Ticking(bool on);

    event ArmedSet(bool armed);
    event TimingSet(uint64 retryAfterBlocks, uint8 maxRetries);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error BadTiming();
    error CallFailed(bytes reason);

    // ---------------------------------------------------------------------------------------------
    // Constants and storage
    // ---------------------------------------------------------------------------------------------

    /// @dev The legacy system contract. On Reactive Network it emits the `Cron` events.
    address public constant CLOCK = 0x0000000000000000000000000000000000fffFfF;

    /// @dev keccak256("Cron10(uint256)"): one tick every ten Reactive Network blocks.
    uint256 public constant TICK_TOPIC = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    /// @dev Keeps a tick well inside the gas cap of a reactive transaction.
    uint256 public constant MAX_WATCHES = 8;

    BellReactive public immutable CONDUCTOR;
    uint256 public immutable FEED_CHAIN_ID;
    address public immutable FEED;

    address public owner;
    /// @notice Reactive Network blocks a venue gets to confirm before it is sent the state again.
    uint64 public retryAfterBlocks;
    /// @notice Rounds of re-sends per update before the watchdog gives up and says so.
    uint8 public maxRetries;
    /// @notice When false the watchdog ignores everything. Its subscriptions stay.
    bool public armed;
    /// @notice True while the watchdog is subscribed to the clock.
    bool public ticking;

    mapping(bytes32 => Watch) public watches;
    bytes32[] internal _open;

    // ---------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------

    /// @param conductor_        The `BellReactive` to watch. Hand its ownership to this contract afterwards.
    /// @param retryAfterBlocks_ Blocks to wait for confirmations before re-sending.
    /// @param maxRetries_       Rounds of re-sends per update.
    constructor(BellReactive conductor_, uint64 retryAfterBlocks_, uint8 maxRetries_) payable {
        if (retryAfterBlocks_ == 0 || maxRetries_ == 0) revert BadTiming();

        CONDUCTOR = conductor_;
        FEED_CHAIN_ID = conductor_.FEED_CHAIN_ID();
        FEED = conductor_.FEED();

        owner = msg.sender;
        retryAfterBlocks = retryAfterBlocks_;
        maxRetries = maxRetries_;
        armed = true;

        emit OwnershipTransferred(address(0), msg.sender);
        emit TimingSet(retryAfterBlocks_, maxRetries_);
        emit ArmedSet(true);

        SYSTEM.subscribe(
            FEED_CHAIN_ID, FEED, MarketTypes.MARKET_UPDATE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Reactive entry point
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == TICK_TOPIC) {
            if (log_.chainId == block.chainid && log_.contractAddress == CLOCK) _onTick();
        } else if (log_.topic0 == MarketTypes.MARKET_UPDATE_TOPIC) {
            if (log_.chainId == FEED_CHAIN_ID && log_.contractAddress == FEED) _onMarketUpdate(log_);
        }
    }

    /// @dev MarketUpdate(bytes32 indexed marketId, uint8 indexed status, uint256 price, uint64 seq, uint64 sourceTime)
    function _onMarketUpdate(LogRecord calldata log_) internal {
        if (!armed || log_.data.length != 96) return;

        (, uint256 seq,) = abi.decode(log_.data, (uint256, uint256, uint256));
        if (seq == 0 || seq > type(uint64).max) return;

        bytes32 marketId = bytes32(log_.topic1);
        Watch storage w = watches[marketId];
        if (seq <= w.seq) return;

        if (!w.open) {
            // Full: this update goes unwatched. The conductor still handles it as it always did.
            if (_open.length == MAX_WATCHES) return;
            w.open = true;
            _open.push(marketId);
        }

        // A newer update starts the count again: the conductor re-sends to lagging venues with it.
        w.seq = uint64(seq);
        w.sinceBlock = uint64(block.number);
        w.retries = 0;

        emit Watching(marketId, uint64(seq));

        if (!ticking) {
            ticking = true;
            SYSTEM.subscribe(block.chainid, CLOCK, TICK_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit Ticking(true);
        }
    }

    /// @dev Looks at every open loop: close it, leave it for the next tick, re-send, or give up.
    function _onTick() internal {
        // A tick that was already on its way when the clock was switched off.
        if (!ticking) return;

        for (uint256 i = _open.length; i != 0; --i) {
            bytes32 marketId = _open[i - 1];
            Watch storage w = watches[marketId];

            (uint8 status, uint64 seenSeq,,) = CONDUCTOR.markets(marketId);
            // The conductor may not have reacted to this update yet. Until it has, its books describe
            // the previous one.
            bool seen = seenSeq >= w.seq;

            if (seen && CONDUCTOR.inSync(marketId)) {
                emit Settled(marketId, w.seq, w.retries);
                _close(i - 1);
                continue;
            }

            if (block.number < uint256(w.sinceBlock) + retryAfterBlocks) continue;

            if (w.retries == maxRetries) {
                emit GaveUp(marketId, w.seq, w.retries);
                _close(i - 1);
                continue;
            }

            ++w.retries;
            w.sinceBlock = uint64(block.number);
            if (seen) _resend(marketId, status, w.seq, w.retries);
        }

        if (_open.length == 0) {
            ticking = false;
            SYSTEM.unsubscribe(block.chainid, CLOCK, TICK_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit Ticking(false);
        }
    }

    /// @dev Has the conductor send the market's current state again to every venue that lags.
    function _resend(bytes32 marketId, uint8 status, uint64 seq, uint8 attempt) internal {
        uint256 count = CONDUCTOR.venueCount();
        for (uint256 venueId = 0; venueId != count; ++venueId) {
            if (!CONDUCTOR.venue(venueId).active) continue;

            (uint64 sentSeq,, uint8 sentStatus, bool awaitingAck,) = CONDUCTOR.links(marketId, venueId);
            // The same test the conductor uses to decide that a venue is not settled.
            if (!awaitingAck && sentSeq != 0 && sentStatus == status) continue;

            try CONDUCTOR.resync(marketId, venueId) {
                emit Retried(marketId, seq, venueId, attempt);
            } catch (bytes memory reason) {
                emit RetryRefused(marketId, venueId, reason);
            }
        }
    }

    function _close(uint256 index) internal {
        watches[_open[index]].open = false;
        _open[index] = _open[_open.length - 1];
        _open.pop();
    }

    // ---------------------------------------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------------------------------------

    /// @notice Switches the watchdog on or off. Switching it off drops every open watch and the clock.
    function setArmed(bool armed_) external onlyOwner {
        armed = armed_;
        emit ArmedSet(armed_);
        if (armed_) return;

        for (uint256 i = _open.length; i != 0; --i) {
            _close(i - 1);
        }
        if (ticking) {
            ticking = false;
            SYSTEM.unsubscribe(block.chainid, CLOCK, TICK_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            emit Ticking(false);
        }
    }

    function setTiming(uint64 retryAfterBlocks_, uint8 maxRetries_) external onlyOwner {
        if (retryAfterBlocks_ == 0 || maxRetries_ == 0) revert BadTiming();
        retryAfterBlocks = retryAfterBlocks_;
        maxRetries = maxRetries_;
        emit TimingSet(retryAfterBlocks_, maxRetries_);
    }

    /// @notice Calls another contract as the watchdog. This is how the owner still runs the conductor
    ///         (add a venue, change a policy, pause, withdraw) once the watchdog owns it.
    function execute(address target, bytes calldata data) external payable onlyOwner returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{ value: msg.value }(data);
        if (!ok) revert CallFailed(result);
    }

    /// @notice Hands the conductor to a new owner. After this the watchdog can no longer re-send.
    function releaseConductor(address to) external onlyOwner {
        CONDUCTOR.transferOwnership(to);
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    /// @notice Settles outstanding debt to the system contract from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "withdraw failed");
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Markets whose loops are open right now.
    function openWatches() external view returns (bytes32[] memory) {
        return _open;
    }
}
