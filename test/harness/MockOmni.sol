// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Reactive Network system contract. Its runtime code is placed at
///         0x8888…8888 by `OmniTest`, so contracts built on `AbstractReactive` work unchanged.
/// @dev    Mirrors the parts of the real contract that a reactive contract can observe:
///         subscriptions, callback requests, reserves and debt. Fees are not modelled.
contract MockSystem is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address emitter;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool live;
    }

    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    event Subscribe(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );
    event Unsubscribe(
        address indexed subscriber,
        uint256 indexed chainId,
        address indexed contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );
    event CallbackRequest(
        uint256 indexed chainId_,
        address indexed sender_,
        address indexed recipient_,
        CallbackVersion version_,
        bytes configuration_
    );

    error InvalidCallbackVersion(CallbackVersion version_);

    Subscription[] public subscriptions;

    mapping(address => uint256) public reserves;
    mapping(address => uint256) internal _debts;

    receive() external payable {
        reserves[msg.sender] += msg.value;
    }

    function depositTo(address contract_) external payable {
        reserves[contract_] += msg.value;
    }

    function debt(address contract_) external view returns (uint256) {
        return _debts[contract_];
    }

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
        external
    {
        subscriptions.push(Subscription(msg.sender, chainId, emitter, topic0, topic1, topic2, topic3, true));
        emit Subscribe(msg.sender, chainId, emitter, topic0, topic1, topic2, topic3);
    }

    function unsubscribe(
        uint256 chainId,
        address emitter,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        uint256 count = subscriptions.length;
        for (uint256 i = 0; i != count; ++i) {
            Subscription storage s = subscriptions[i];
            if (
                s.live && s.subscriber == msg.sender && s.chainId == chainId && s.emitter == emitter
                    && s.topic0 == topic0 && s.topic1 == topic1 && s.topic2 == topic2 && s.topic3 == topic3
            ) {
                s.live = false;
            }
        }
        emit Unsubscribe(msg.sender, chainId, emitter, topic0, topic1, topic2, topic3);
    }

    /// @dev Like the real contract, a request is nothing more than an event. The simulator picks it up
    ///      from the log stream, so `react()` costs about the same gas here as it does on the network.
    function requestCallback(CallbackVersion version_, bytes memory config_) external {
        if (version_ != CallbackVersion.V_1_0) revert InvalidCallbackVersion(version_);
        CallbackConfiguration_V_1_0 memory config = abi.decode(config_, (CallbackConfiguration_V_1_0));
        emit CallbackRequest(config.chainId, msg.sender, config.recipient, version_, config_);
    }

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        emit CallbackRequest(config_.chainId, msg.sender, config_.recipient, CallbackVersion.V_1_0, abi.encode(config_));
    }

    // ------------------------------------------------------------------------------------------
    // Simulator-only surface
    // ------------------------------------------------------------------------------------------

    /// @notice Subscribers whose criteria match a log. Each subscriber is listed once per matching
    ///         subscription, which is how duplicate subscriptions behave on the real network's worst day.
    function matching(uint256 chainId, address emitter, bytes32[] memory topics)
        external
        view
        returns (address[] memory subscribers)
    {
        uint256 count = subscriptions.length;
        address[] memory found = new address[](count);
        uint256 n;

        for (uint256 i = 0; i != count; ++i) {
            Subscription storage s = subscriptions[i];
            if (!s.live) continue;
            if (s.chainId != 0 && s.chainId != chainId) continue;
            if (s.emitter != address(0) && s.emitter != emitter) continue;
            if (!_topicMatches(s.topic0, topics, 0)) continue;
            if (!_topicMatches(s.topic1, topics, 1)) continue;
            if (!_topicMatches(s.topic2, topics, 2)) continue;
            if (!_topicMatches(s.topic3, topics, 3)) continue;

            bool seen;
            for (uint256 j = 0; j != n; ++j) {
                if (found[j] == s.subscriber) {
                    seen = true;
                    break;
                }
            }
            if (!seen) found[n++] = s.subscriber;
        }

        subscribers = new address[](n);
        for (uint256 i = 0; i != n; ++i) {
            subscribers[i] = found[i];
        }
    }

    function _topicMatches(uint256 wanted, bytes32[] memory topics, uint256 index) internal pure returns (bool) {
        if (wanted == REACTIVE_IGNORE) return true;
        return index < topics.length && uint256(topics[index]) == wanted;
    }
}

/// @notice Stand-in for a destination chain's callback proxy. One instance per simulated chain.
contract MockCallbackProxy {
    event CallbackFailure(address indexed target_, bytes payload_);

    mapping(address => uint256) public reserves;
    mapping(address => uint256) internal _debts;

    receive() external payable {
        reserves[msg.sender] += msg.value;
    }

    function depositTo(address contract_) external payable {
        reserves[contract_] += msg.value;
    }

    function debt(address contract_) external view returns (uint256) {
        return _debts[contract_];
    }

    /// @dev Like the real proxy, a failing callback is logged, not bubbled up.
    function deliver(address recipient, bytes memory payload, uint256 gasForCallback) external returns (bool ok) {
        (ok,) = recipient.call{ gas: gasForCallback }(payload);
        if (!ok) emit CallbackFailure(recipient, payload);
    }
}
