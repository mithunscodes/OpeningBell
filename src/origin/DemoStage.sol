// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MarketTypes } from "../common/MarketTypes.sol";
import { MarketFeed } from "./MarketFeed.sol";

/// @title DemoStage
/// @notice Lets anyone play the part of the stock exchange in the demo: ring the closing bell, halt
///         trading, reopen at a different price. Each action publishes one observation on the
///         `MarketFeed`, which is what sets the whole cross-chain loop in motion.
/// @dev    Every public action costs the project real testnet funds on Reactive Network (the
///         conductor pays for its reactions), so actions are rate-limited: one every `cooldown`
///         seconds for everybody together, and `dailyCap` per day. The owner is not limited.
contract DemoStage {
    event Staged(address indexed by, uint8 status, int16 moveBps, uint256 price, uint64 seq);
    event LimitsSet(uint32 cooldown, uint32 dailyCap, bool paused);

    error NotOwner();
    error Paused();
    error CoolingDown(uint256 readyAt);
    error DailyCapReached();
    error MoveTooLarge();

    /// @dev Largest move one action can make: 20% either way.
    int16 public constant MAX_MOVE_BPS = 2_000;

    /// @dev If the pretend price wanders outside this corridor it snaps back to `RESET_PRICE`.
    uint256 public constant MIN_PRICE = 20e18;
    uint256 public constant MAX_PRICE = 1_000e18;
    uint256 public constant RESET_PRICE = 140e18;

    MarketFeed public immutable FEED;
    bytes32 public immutable MARKET_ID;

    address public owner;
    bool public paused;
    uint32 public cooldown;
    uint32 public dailyCap;

    uint64 public lastActionAt;
    uint64 public countedDay;
    uint32 public usedToday;

    constructor(MarketFeed feed_, bytes32 marketId_, uint32 cooldown_, uint32 dailyCap_) {
        FEED = feed_;
        MARKET_ID = marketId_;
        owner = msg.sender;
        cooldown = cooldown_;
        dailyCap = dailyCap_;
    }

    // ---------------------------------------------------------------------------------------------
    // The buttons
    // ---------------------------------------------------------------------------------------------

    /// @notice Trading is suspended. The price stays where it is.
    function halt() external returns (uint64) {
        return _act(MarketTypes.HALTED, 0);
    }

    /// @notice Trading resumes (or the day starts) at a price `gapBps` away from the last one.
    function open(int16 gapBps) external returns (uint64) {
        return _act(MarketTypes.OPEN, gapBps);
    }

    /// @notice The closing bell. The price becomes the day's close.
    function close() external returns (uint64) {
        return _act(MarketTypes.CLOSED, 0);
    }

    /// @notice Any status with any move, for scripted scenarios.
    function act(uint8 status, int16 moveBps) external returns (uint64) {
        return _act(status, moveBps);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice When the next public action is allowed, and how many are left today.
    function availability() external view returns (uint256 readyAt, uint256 leftToday) {
        readyAt = uint256(lastActionAt) + cooldown;
        uint256 used = block.timestamp / 1 days == countedDay ? usedToday : 0;
        leftToday = used >= dailyCap ? 0 : dailyCap - used;
    }

    // ---------------------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------------------

    function setLimits(uint32 cooldown_, uint32 dailyCap_, bool paused_) external {
        if (msg.sender != owner) revert NotOwner();
        cooldown = cooldown_;
        dailyCap = dailyCap_;
        paused = paused_;
        emit LimitsSet(cooldown_, dailyCap_, paused_);
    }

    function transferOwnership(address to) external {
        if (msg.sender != owner) revert NotOwner();
        owner = to;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _act(uint8 status, int16 moveBps) internal returns (uint64 seq) {
        if (moveBps > MAX_MOVE_BPS || moveBps < -MAX_MOVE_BPS) revert MoveTooLarge();

        if (msg.sender != owner) {
            if (paused) revert Paused();

            uint256 readyAt = uint256(lastActionAt) + cooldown;
            if (block.timestamp < readyAt) revert CoolingDown(readyAt);

            uint64 today = uint64(block.timestamp / 1 days);
            if (today != countedDay) {
                countedDay = today;
                usedToday = 0;
            }
            if (usedToday >= dailyCap) revert DailyCapReached();
            ++usedToday;
        }
        lastActionAt = uint64(block.timestamp);

        (,,, uint256 price) = FEED.markets(MARKET_ID);
        if (price == 0) {
            price = RESET_PRICE;
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            price = price * uint256(int256(10_000) + moveBps) / 10_000;
            if (price < MIN_PRICE || price > MAX_PRICE) price = RESET_PRICE;
        }

        seq = FEED.publish(MARKET_ID, status, price, uint64(block.timestamp));
        emit Staged(msg.sender, status, moveBps, price, seq);
    }
}
