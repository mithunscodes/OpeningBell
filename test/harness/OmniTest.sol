// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { MockSystem, MockCallbackProxy } from "./MockOmni.sol";

/// @title OmniTest
/// @notice A small local model of Reactive Network Omni for `forge test`.
/// @dev    Every contract lives in one EVM. "Chains" are labels: `_place(contract, chainId)` says which
///         chain a contract is pretending to be on. `_pump()` then plays the network's part:
///
///         1. take every log emitted since the last pump,
///         2. hand each one to every reactive contract whose subscription matches (as the system
///            contract),
///         3. deliver every `CallbackRequest` the system contract emitted (as the destination chain's
///            proxy, after writing the requesting contract's address into the first argument),
///         4. repeat with the logs those calls produced, until nothing is left.
///
///         What it does not model: fees, debt, block times, re-orgs. Latency is measured on the
///         real networks, not here.
abstract contract OmniTest is Test {
    MockSystem internal constant OMNI = MockSystem(payable(0x8888888888888888888888888888888888888888));

    uint256 internal constant LASNA = 5318007;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;

    /// @dev Upper bound on feedback rounds in one pump. A loop that needs more is a bug.
    uint256 internal constant MAX_ROUNDS = 32;

    bytes32 internal constant CALLBACK_REQUEST_SIG = keccak256("CallbackRequest(uint256,address,address,uint8,bytes)");

    mapping(uint256 => MockCallbackProxy) internal _proxies;
    mapping(address => uint256) internal _chainOf;

    /// @dev Every log the simulator has seen, oldest first. Tests search it with `_count`.
    Vm.Log[] internal _history;

    uint256 public reactions;
    uint256 public reactionReverts;
    /// @dev Callback requests seen, including those for chains that are down.
    uint256 public requests;
    uint256 public deliveries;
    uint256 public deliveryFailures;

    /// @dev Set to true to stop callbacks from being delivered (a dead destination chain).
    mapping(uint256 => bool) internal _chainDown;

    function _omniSetUp() internal {
        vm.etch(address(OMNI), address(new MockSystem()).code);
        vm.label(address(OMNI), "SystemContract");
        vm.recordLogs();
    }

    function _proxy(uint256 chainId) internal returns (MockCallbackProxy proxy) {
        proxy = _proxies[chainId];
        if (address(proxy) == address(0)) {
            proxy = new MockCallbackProxy();
            _proxies[chainId] = proxy;
            vm.label(address(proxy), string.concat("CallbackProxy@", vm.toString(chainId)));
        }
    }

    function _place(address target, uint256 chainId) internal {
        _chainOf[target] = chainId;
    }

    /// @notice Runs the simulated network until it is quiet.
    function _pump() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 round = 0; round != MAX_ROUNDS; ++round) {
            if (logs.length == 0) return;

            for (uint256 i = 0; i != logs.length; ++i) {
                _history.push(logs[i]);
                if (logs[i].emitter == address(OMNI)) {
                    if (logs[i].topics[0] == CALLBACK_REQUEST_SIG) _deliver(logs[i]);
                } else {
                    _dispatch(logs[i], i);
                }
            }

            logs = vm.getRecordedLogs();
        }

        revert("OmniTest: network did not settle");
    }

    function _dispatch(Vm.Log memory log, uint256 logIndex) internal {
        uint256 chainId = _chainOf[log.emitter];
        if (chainId == 0) return;

        address[] memory subscribers = OMNI.matching(chainId, log.emitter, log.topics);
        if (subscribers.length == 0) return;

        IReactive.LogRecord memory record = IReactive.LogRecord({
            chainId: chainId,
            contractAddress: log.emitter,
            topic0: _topic(log, 0),
            topic1: _topic(log, 1),
            topic2: _topic(log, 2),
            topic3: _topic(log, 3),
            data: log.data,
            blockNumber: block.number,
            opCode: log.topics.length,
            blockHash: uint256(keccak256(abi.encode("block", chainId, block.number))),
            txHash: uint256(keccak256(abi.encode("tx", chainId, _history.length))),
            logIndex: logIndex
        });

        for (uint256 i = 0; i != subscribers.length; ++i) {
            ++reactions;
            vm.prank(address(OMNI));
            try IReactive(payable(subscribers[i])).react(record) { }
            catch {
                ++reactionReverts;
            }
        }
    }

    /// @dev CallbackRequest(uint256 indexed chainId, address indexed sender, address indexed recipient, uint8 version, bytes config)
    function _deliver(Vm.Log memory request) internal {
        address sender = address(uint160(uint256(request.topics[2])));
        (, bytes memory encoded) = abi.decode(request.data, (uint8, bytes));
        ISystemContract.CallbackConfiguration_V_1_0 memory config =
            abi.decode(encoded, (ISystemContract.CallbackConfiguration_V_1_0));

        ++requests;
        if (_chainDown[config.chainId]) return;

        MockCallbackProxy proxy = _proxies[config.chainId];
        require(address(proxy) != address(0), "OmniTest: no proxy for chain");

        // The network overwrites the first argument with the address of the requesting contract.
        bytes memory payload = config.payload;
        require(payload.length >= 36, "OmniTest: payload has no first argument");
        assembly ("memory-safe") {
            mstore(add(payload, 36), sender)
        }

        ++deliveries;
        if (!proxy.deliver(config.recipient, payload, config.gasLimit)) {
            ++deliveryFailures;
        }
    }

    function _topic(Vm.Log memory log, uint256 index) private pure returns (uint256) {
        return index < log.topics.length ? uint256(log.topics[index]) : 0;
    }

    /// @notice Number of logs in the history with this emitter and event signature.
    function _count(address emitter, bytes32 topic0) internal view returns (uint256 n) {
        uint256 length = _history.length;
        for (uint256 i = 0; i != length; ++i) {
            Vm.Log storage log = _history[i];
            if (log.emitter == emitter && log.topics.length != 0 && log.topics[0] == topic0) ++n;
        }
    }

    /// @notice The most recent log in the history with this emitter and event signature.
    function _last(address emitter, bytes32 topic0) internal view returns (Vm.Log memory) {
        for (uint256 i = _history.length; i != 0; --i) {
            Vm.Log storage log = _history[i - 1];
            if (log.emitter == emitter && log.topics.length != 0 && log.topics[0] == topic0) return log;
        }
        revert("OmniTest: no such log");
    }
}
