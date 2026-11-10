// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IRefPrice } from "../common/MarketTypes.sol";

/// @notice Implemented by contracts that want to act the moment a market state lands on this chain.
interface IMarketListener {
    function onMarketState(bytes32 marketId, uint8 status, uint256 price, uint24 feePips, uint24 halfRangeBps) external;
}

/// @title BellGuard
/// @notice The on-chain copy of a reference market's state on a venue chain. It is written only by
///         Reactive Network callbacks and read by pools, vaults and anything else that needs to know
///         whether the reference market is open.
contract BellGuard is AbstractCallback, IRefPrice {
    struct State {
        uint8 status;
        uint64 seq;
        uint64 appliedAt;
        uint24 feePips;
        uint24 halfRangeBps;
        uint256 price;
    }

    /// @notice Emitted for every state that is applied. `originBlock` and `originTxHash` identify the
    ///         feed event that started the loop, so one log links the whole loop together.
    event Applied(
        bytes32 indexed marketId,
        uint64 indexed seq,
        uint8 status,
        uint256 price,
        uint24 feePips,
        uint24 halfRangeBps,
        uint256 originBlock,
        uint256 originTxHash
    );

    /// @notice Emitted only when the reactive contract asked for a confirmation. It subscribes to this.
    event Ack(bytes32 indexed marketId, uint64 indexed seq, uint8 status);

    /// @notice A callback arrived out of order and was ignored.
    event Stale(bytes32 indexed marketId, uint64 seq, uint64 currentSeq);

    /// @notice The listener reverted. The state is still applied, so readers stay correct.
    event ListenerFailed(bytes32 indexed marketId, address listener, bytes reason);

    event ListenerSet(bytes32 indexed marketId, address listener);

    error NotOwner();

    /// @dev Gas kept back so the guard can finish after a listener burns everything it was given.
    uint256 internal constant LISTENER_GAS_RESERVE = 60_000;

    address public owner;
    mapping(bytes32 => State) public states;
    mapping(bytes32 => address) public listeners;

    constructor(IPayable callbackProxy_, address reactive_) payable AbstractCallback(callbackProxy_, reactive_) {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setListener(bytes32 marketId, address listener) external onlyOwner {
        listeners[marketId] = listener;
        emit ListenerSet(marketId, listener);
    }

    function transferOwnership(address to) external onlyOwner {
        owner = to;
    }

    /// @notice Lets the owner settle any debt to the callback proxy from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{ value: amount }("");
        require(ok, "withdraw failed");
    }

    /// @notice Entry point for Reactive Network callbacks.
    /// @param reactive_ Filled in by the network with the address of the requesting reactive contract.
    function applyState(
        address reactive_,
        bytes32 marketId,
        uint64 seq,
        uint8 status,
        uint256 price,
        uint24 feePips,
        uint24 halfRangeBps,
        bool wantAck,
        uint256 originBlock,
        uint256 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        State storage s = states[marketId];

        // Older than what is already applied: ignore. The same sequence number is applied again, which
        // is how the reactive contract re-sends a state after a policy change.
        if (seq < s.seq) {
            emit Stale(marketId, seq, s.seq);
            return;
        }

        s.status = status;
        s.seq = seq;
        s.appliedAt = uint64(block.timestamp);
        s.feePips = feePips;
        s.halfRangeBps = halfRangeBps;
        s.price = price;

        emit Applied(marketId, seq, status, price, feePips, halfRangeBps, originBlock, originTxHash);

        address listener = listeners[marketId];
        if (listener != address(0)) {
            uint256 budget = gasleft() > LISTENER_GAS_RESERVE ? gasleft() - LISTENER_GAS_RESERVE : 0;
            try IMarketListener(listener).onMarketState{ gas: budget }(
                marketId, status, price, feePips, halfRangeBps
            ) { }
            catch (bytes memory reason) {
                emit ListenerFailed(marketId, listener, reason);
            }
        }

        if (wantAck) {
            emit Ack(marketId, seq, status);
        }
    }

    /// @notice Convenience view for integrators.
    function current(bytes32 marketId)
        external
        view
        returns (uint8 status, uint256 price, uint24 feePips, uint24 halfRangeBps, uint64 seq, uint64 appliedAt)
    {
        State storage s = states[marketId];
        return (s.status, s.price, s.feePips, s.halfRangeBps, s.seq, s.appliedAt);
    }

    /// @inheritdoc IRefPrice
    function priceOf(bytes32 marketId) external view returns (uint256) {
        return states[marketId].price;
    }
}
