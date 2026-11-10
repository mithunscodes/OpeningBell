// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { MarketTypes, IRefPrice } from "../common/MarketTypes.sol";

/// @title MarketFeed
/// @notice Publishes the state of a reference market (for example a stock on its home exchange):
///         whether it is open, closed or halted, and the reference price.
/// @dev On a testnet nobody publishes equity prices, so authorised publishers replay real market data.
///      In production this contract is replaced by an existing on-chain equity feed; the only thing the
///      rest of the system depends on is the `MarketUpdate` event.
contract MarketFeed is IRefPrice {
    struct Market {
        uint8 status;
        uint64 seq;
        uint64 sourceTime;
        uint256 price;
    }

    /// @param marketId   Identifier of the reference market, for example keccak256("NVDA/USD").
    /// @param status     One of `MarketTypes.CLOSED`, `OPEN`, `HALTED`.
    /// @param price      Reference price in USD with 18 decimals.
    /// @param seq        Strictly increasing sequence number per market.
    /// @param sourceTime Timestamp of the observation at the source, in seconds.
    event MarketUpdate(bytes32 indexed marketId, uint8 indexed status, uint256 price, uint64 seq, uint64 sourceTime);

    event PublisherSet(address indexed publisher, bool allowed);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotOwner();
    error NotPublisher();
    error BadStatus(uint8 status);
    error BadPrice();

    address public owner;
    mapping(address => bool) public publishers;
    mapping(bytes32 => Market) public markets;

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    function setPublisher(address publisher, bool allowed) external onlyOwner {
        publishers[publisher] = allowed;
        emit PublisherSet(publisher, allowed);
    }

    /// @notice Publishes a new observation for a market.
    function publish(bytes32 marketId, uint8 status, uint256 price, uint64 sourceTime) external returns (uint64 seq) {
        if (!publishers[msg.sender]) revert NotPublisher();
        if (status > MarketTypes.HALTED) revert BadStatus(status);
        if (price == 0) revert BadPrice();

        Market storage m = markets[marketId];
        seq = m.seq + 1;
        m.status = status;
        m.seq = seq;
        m.sourceTime = sourceTime;
        m.price = price;

        emit MarketUpdate(marketId, status, price, seq, sourceTime);
    }

    /// @inheritdoc IRefPrice
    function priceOf(bytes32 marketId) external view returns (uint256) {
        return markets[marketId].price;
    }
}
