// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { MarketTypes } from "../common/MarketTypes.sol";
import { BellGuard } from "../venue/BellGuard.sol";

/// @title BellReactive
/// @notice The conductor. It lives on Reactive Network, listens to one market feed on the origin
///         chain, decides what each trading venue should do about it, and sends that decision to
///         every venue on every chain in the same reactive transaction.
/// @dev    One feed event in, one callback per venue out. Venues confirm with an `Ack` event that this
///         contract also subscribes to, which gives it an on-chain view of which venues are in sync
///         and lets it re-send to a venue that never confirmed.
///
///         `react()` never reverts on bad input: a reverting reactive transaction is still charged.
contract BellReactive is AbstractReactive {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice What a venue should do while the reference market is in a given status.
    /// @param feePips      Swap fee in hundredths of a basis point (3000 = 0.30%).
    /// @param halfRangeBps Half-width of the liquidity band around the reference price, in basis
    ///                     points. Zero means "hold no liquidity in the pool".
    struct Policy {
        uint24 feePips;
        uint24 halfRangeBps;
    }

    struct Venue {
        uint256 chainId;
        address guard;
        uint64 gasLimit;
        /// @dev Price-only updates smaller than this (in basis points of the last price sent) are not
        ///      forwarded. Status changes are always forwarded.
        uint16 minMoveBps;
        bool active;
        /// @dev Indexed by market status: CLOSED, OPEN, HALTED.
        Policy[3] policy;
    }

    /// @dev Latest observation accepted from the feed. One storage slot.
    struct Market {
        uint8 status;
        uint64 seq;
        uint64 sourceTime;
        uint112 price;
    }

    /// @dev What this contract last told a venue about a market, and what the venue confirmed. One slot.
    struct Link {
        uint64 sentSeq;
        uint64 ackedSeq;
        uint8 sentStatus;
        bool awaitingAck;
        uint112 sentPrice;
    }

    enum AckMode {
        /// @dev Fire and forget. Cheapest.
        Never,
        /// @dev Ask for a confirmation when the market status changes.
        OnStatusChange,
        /// @dev Ask for a confirmation on every forwarded update. Used when measuring latency.
        Always
    }

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice A feed observation was accepted. `originBlock` and `originTxHash` identify the feed event.
    event Observed(
        bytes32 indexed marketId,
        uint64 indexed seq,
        uint8 status,
        uint256 price,
        uint256 originBlock,
        uint256 originTxHash
    );

    /// @notice A callback was requested for a venue.
    event Forwarded(
        bytes32 indexed marketId,
        uint64 indexed seq,
        uint256 indexed venueId,
        uint8 status,
        uint256 price,
        uint24 feePips,
        uint24 halfRangeBps,
        bool wantAck
    );

    /// @notice A price-only update was too small to be worth a callback to this venue.
    event Filtered(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId);

    /// @notice A venue confirmed that it applied a state.
    event VenueAcked(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId, uint8 status);

    /// @notice No active venue owes a confirmation any more: all of them hold the market's current status.
    event LoopClosed(bytes32 indexed marketId, uint64 indexed seq);

    /// @notice A log was ignored. See the `IGNORED_*` constants.
    event Ignored(uint256 indexed reason, uint256 chainId, address emitter, uint256 txHash);

    event VenueAdded(uint256 indexed venueId, uint256 indexed chainId, address indexed guard);
    event VenueUpdated(uint256 indexed venueId);
    event AckModeSet(AckMode mode);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error NotOwner();
    error BadVenue();
    error VenueExists();
    error TooManyVenues();
    error GasLimitTooLow();
    error UnknownMarket();

    // ---------------------------------------------------------------------------------------------
    // Constants and storage
    // ---------------------------------------------------------------------------------------------

    uint256 public constant IGNORED_STALE = 1;
    uint256 public constant IGNORED_MALFORMED = 2;
    uint256 public constant IGNORED_UNKNOWN_SOURCE = 3;
    uint256 public constant IGNORED_PAUSED = 4;

    /// @dev Reactive Network ignores callback requests below this gas limit.
    uint64 public constant MIN_CALLBACK_GAS = 100_000;

    /// @dev Keeps the fan-out loop well inside the 900k gas cap of a reactive transaction.
    uint256 public constant MAX_VENUES = 8;

    uint256 public immutable FEED_CHAIN_ID;
    address public immutable FEED;

    address public owner;
    AckMode public ackMode;
    bool public paused;

    Venue[] internal _venues;
    /// @dev chainId => guard => venueId + 1
    mapping(uint256 => mapping(address => uint256)) internal _venueIndex;

    mapping(bytes32 => Market) public markets;
    /// @dev marketId => venueId => link
    mapping(bytes32 => mapping(uint256 => Link)) public links;

    // ---------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------

    /// @param feedChainId_ Chain the market feed lives on.
    /// @param feed_        Address of the `MarketFeed`.
    /// @param ackMode_     When to ask venues for confirmations.
    constructor(uint256 feedChainId_, address feed_, AckMode ackMode_) payable {
        FEED_CHAIN_ID = feedChainId_;
        FEED = feed_;
        owner = msg.sender;
        ackMode = ackMode_;

        emit OwnershipTransferred(address(0), msg.sender);
        emit AckModeSet(ackMode_);

        SYSTEM.subscribe(
            feedChainId_, feed_, MarketTypes.MARKET_UPDATE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
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
        if (paused) {
            emit Ignored(IGNORED_PAUSED, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        if (log_.topic0 == MarketTypes.MARKET_UPDATE_TOPIC) {
            if (log_.chainId == FEED_CHAIN_ID && log_.contractAddress == FEED) {
                _onMarketUpdate(log_);
                return;
            }
        } else if (log_.topic0 == MarketTypes.ACK_TOPIC) {
            uint256 index = _venueIndex[log_.chainId][log_.contractAddress];
            if (index != 0) {
                _onAck(index - 1, log_);
                return;
            }
        }

        emit Ignored(IGNORED_UNKNOWN_SOURCE, log_.chainId, log_.contractAddress, log_.txHash);
    }

    /// @dev MarketUpdate(bytes32 indexed marketId, uint8 indexed status, uint256 price, uint64 seq, uint64 sourceTime)
    function _onMarketUpdate(LogRecord calldata log_) internal {
        if (log_.data.length != 96 || log_.topic2 > MarketTypes.HALTED) {
            emit Ignored(IGNORED_MALFORMED, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        (uint256 price, uint256 seq, uint256 sourceTime) = abi.decode(log_.data, (uint256, uint256, uint256));
        if (price == 0 || price > type(uint112).max || seq > type(uint64).max || sourceTime > type(uint64).max) {
            emit Ignored(IGNORED_MALFORMED, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        bytes32 marketId = bytes32(log_.topic1);
        uint8 status = uint8(log_.topic2);
        Market storage m = markets[marketId];

        // Logs can in principle arrive out of order. The newest observation always wins.
        if (seq <= m.seq) {
            emit Ignored(IGNORED_STALE, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        m.status = status;
        m.seq = uint64(seq);
        m.sourceTime = uint64(sourceTime);
        m.price = uint112(price);

        emit Observed(marketId, uint64(seq), status, price, log_.blockNumber, log_.txHash);

        _fanOut(marketId, log_.blockNumber, log_.txHash);
    }

    /// @dev Decides, venue by venue, whether the newest observation is worth a callback.
    function _fanOut(bytes32 marketId, uint256 originBlock, uint256 originTxHash) internal {
        Market memory m = markets[marketId];
        uint256 count = _venues.length;

        for (uint256 venueId = 0; venueId != count; ++venueId) {
            Venue storage v = _venues[venueId];
            if (!v.active) continue;

            Link storage l = links[marketId][venueId];
            bool statusChanged = l.sentSeq == 0 || l.sentStatus != m.status;

            // A venue that owes a confirmation gets the new state no matter how small the move is.
            if (!statusChanged && !l.awaitingAck && !_movedEnough(l.sentPrice, m.price, v.minMoveBps)) {
                emit Filtered(marketId, m.seq, venueId);
                continue;
            }

            _forward(marketId, venueId, m, statusChanged, originBlock, originTxHash);
        }
    }

    /// @dev Ack(bytes32 indexed marketId, uint64 indexed seq, uint8 status)
    function _onAck(uint256 venueId, LogRecord calldata log_) internal {
        if (log_.data.length != 32 || log_.topic2 > type(uint64).max) {
            emit Ignored(IGNORED_MALFORMED, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        bytes32 marketId = bytes32(log_.topic1);
        uint64 seq = uint64(log_.topic2);
        Link storage l = links[marketId][venueId];

        if (seq <= l.ackedSeq || seq > l.sentSeq) {
            emit Ignored(IGNORED_STALE, log_.chainId, log_.contractAddress, log_.txHash);
            return;
        }

        l.ackedSeq = seq;
        emit VenueAcked(marketId, seq, venueId, uint8(abi.decode(log_.data, (uint256))));

        // Only a confirmation of the newest state sent to this venue settles it.
        if (seq != l.sentSeq) return;
        l.awaitingAck = false;

        if (_settled(marketId)) {
            emit LoopClosed(marketId, markets[marketId].seq);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _forward(
        bytes32 marketId,
        uint256 venueId,
        Market memory m,
        bool statusChanged,
        uint256 originBlock,
        uint256 originTxHash
    ) internal {
        Venue storage v = _venues[venueId];
        Link storage l = links[marketId][venueId];
        Policy memory p = v.policy[m.status];

        // While a confirmation is outstanding, keep asking: only a confirmation of the newest state counts.
        bool wantAck =
            l.awaitingAck || ackMode == AckMode.Always || (ackMode == AckMode.OnStatusChange && statusChanged);

        l.sentSeq = m.seq;
        l.sentStatus = m.status;
        l.sentPrice = m.price;
        l.awaitingAck = wantAck;

        // The first argument is a placeholder: the network overwrites it with this contract's address.
        bytes memory payload = abi.encodeCall(
            BellGuard.applyState,
            (
                address(0),
                marketId,
                m.seq,
                m.status,
                uint256(m.price),
                p.feePips,
                p.halfRangeBps,
                wantAck,
                originBlock,
                originTxHash
            )
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: v.chainId, recipient: v.guard, gasLimit: v.gasLimit, payload: payload
            })
        );

        emit Forwarded(marketId, m.seq, venueId, m.status, m.price, p.feePips, p.halfRangeBps, wantAck);
    }

    function _movedEnough(uint256 from, uint256 to, uint256 minMoveBps) internal pure returns (bool) {
        if (minMoveBps == 0) return true;
        uint256 diff = from > to ? from - to : to - from;
        return diff * 10_000 >= from * minMoveBps;
    }

    /// @dev True when no active venue owes a confirmation and each one has been sent the market's
    ///      current status. A venue that skipped a small price move is still settled.
    function _settled(bytes32 marketId) internal view returns (bool) {
        uint8 status = markets[marketId].status;
        uint256 count = _venues.length;
        for (uint256 venueId = 0; venueId != count; ++venueId) {
            if (!_venues[venueId].active) continue;
            Link storage l = links[marketId][venueId];
            if (l.awaitingAck || l.sentSeq == 0 || l.sentStatus != status) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------------------------------------

    /// @notice Registers a venue and starts listening for its confirmations.
    /// @param policy_ Policy for CLOSED, OPEN and HALTED, in that order.
    function addVenue(
        uint256 chainId_,
        address guard_,
        uint64 gasLimit_,
        uint16 minMoveBps_,
        Policy[3] calldata policy_
    ) external onlyOwner returns (uint256 venueId) {
        if (guard_ == address(0) || chainId_ == 0) revert BadVenue();
        if (_venueIndex[chainId_][guard_] != 0) revert VenueExists();
        if (_venues.length == MAX_VENUES) revert TooManyVenues();
        if (gasLimit_ < MIN_CALLBACK_GAS) revert GasLimitTooLow();

        venueId = _venues.length;
        Venue storage v = _venues.push();
        v.chainId = chainId_;
        v.guard = guard_;
        v.gasLimit = gasLimit_;
        v.minMoveBps = minMoveBps_;
        v.active = true;
        for (uint256 i = 0; i != 3; ++i) {
            v.policy[i] = policy_[i];
        }
        _venueIndex[chainId_][guard_] = venueId + 1;

        SYSTEM.subscribe(chainId_, guard_, MarketTypes.ACK_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);

        emit VenueAdded(venueId, chainId_, guard_);
    }

    /// @notice Changes how a venue is driven. Takes effect on the next forwarded update.
    function updateVenue(
        uint256 venueId,
        uint64 gasLimit_,
        uint16 minMoveBps_,
        bool active_,
        Policy[3] calldata policy_
    ) external onlyOwner {
        if (venueId >= _venues.length) revert BadVenue();
        if (gasLimit_ < MIN_CALLBACK_GAS) revert GasLimitTooLow();

        Venue storage v = _venues[venueId];
        v.gasLimit = gasLimit_;
        v.minMoveBps = minMoveBps_;
        v.active = active_;
        for (uint256 i = 0; i != 3; ++i) {
            v.policy[i] = policy_[i];
        }

        emit VenueUpdated(venueId);
    }

    /// @notice Re-sends the latest known state of a market to one venue. Useful after a venue was
    ///         re-activated, re-funded, or had its policy changed.
    function resync(bytes32 marketId, uint256 venueId) external onlyOwner {
        if (venueId >= _venues.length) revert BadVenue();
        Market memory m = markets[marketId];
        if (m.seq == 0) revert UnknownMarket();

        _forward(marketId, venueId, m, true, 0, 0);
    }

    function setAckMode(AckMode mode) external onlyOwner {
        ackMode = mode;
        emit AckModeSet(mode);
    }

    /// @notice Stops acting on events without touching subscriptions. Events still cost gas while paused.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
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

    function venueCount() external view returns (uint256) {
        return _venues.length;
    }

    function venue(uint256 venueId) external view returns (Venue memory) {
        return _venues[venueId];
    }

    function venueIdOf(uint256 chainId_, address guard_) external view returns (bool found, uint256 venueId) {
        uint256 index = _venueIndex[chainId_][guard_];
        return index == 0 ? (false, 0) : (true, index - 1);
    }

    /// @notice True when every active venue has been sent the market's current status and none of
    ///         them owes a confirmation.
    function inSync(bytes32 marketId) external view returns (bool) {
        return markets[marketId].seq != 0 && _settled(marketId);
    }
}
