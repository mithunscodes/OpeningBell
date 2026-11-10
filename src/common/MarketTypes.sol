// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Shared constants for the OpeningBell market state machine.
library MarketTypes {
    /// @dev The reference market is shut (overnight, weekend). The feed price is the last close.
    uint8 internal constant CLOSED = 0;
    /// @dev The reference market is trading. The feed price is live.
    uint8 internal constant OPEN = 1;
    /// @dev Trading in the reference market is suspended (news pending, volatility pause).
    uint8 internal constant HALTED = 2;

    /// @dev keccak256("MarketUpdate(bytes32,uint8,uint256,uint64,uint64)")
    uint256 internal constant MARKET_UPDATE_TOPIC =
        uint256(keccak256("MarketUpdate(bytes32,uint8,uint256,uint64,uint64)"));

    /// @dev keccak256("Ack(bytes32,uint64,uint8)")
    uint256 internal constant ACK_TOPIC = uint256(keccak256("Ack(bytes32,uint64,uint8)"));
}

/// @notice Anything that can say what a reference market is worth right now.
interface IRefPrice {
    /// @return price Reference price in USD with 18 decimals. Zero if the market is unknown.
    function priceOf(bytes32 marketId) external view returns (uint256 price);
}
