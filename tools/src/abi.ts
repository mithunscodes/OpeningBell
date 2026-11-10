import { parseAbi, toEventSelector } from "viem";

export const feedAbi = parseAbi([
  "event MarketUpdate(bytes32 indexed marketId, uint8 indexed status, uint256 price, uint64 seq, uint64 sourceTime)",
  "function publish(bytes32 marketId, uint8 status, uint256 price, uint64 sourceTime) returns (uint64)",
  "function markets(bytes32 marketId) view returns (uint8 status, uint64 seq, uint64 sourceTime, uint256 price)",
  "function publishers(address) view returns (bool)",
]);

export const stageAbi = parseAbi([
  "event Staged(address indexed by, uint8 status, int16 moveBps, uint256 price, uint64 seq)",
  "function act(uint8 status, int16 moveBps) returns (uint64)",
  "function availability() view returns (uint256 readyAt, uint256 leftToday)",
  "function owner() view returns (address)",
]);

export const guardAbi = parseAbi([
  "event Applied(bytes32 indexed marketId, uint64 indexed seq, uint8 status, uint256 price, uint24 feePips, uint24 halfRangeBps, uint256 originBlock, uint256 originTxHash)",
  "event Ack(bytes32 indexed marketId, uint64 indexed seq, uint8 status)",
  "event Stale(bytes32 indexed marketId, uint64 seq, uint64 currentSeq)",
  "event ListenerFailed(bytes32 indexed marketId, address listener, bytes reason)",
  "function current(bytes32 marketId) view returns (uint8 status, uint256 price, uint24 feePips, uint24 halfRangeBps, uint64 seq, uint64 appliedAt)",
]);

export const conductorAbi = parseAbi([
  "event Observed(bytes32 indexed marketId, uint64 indexed seq, uint8 status, uint256 price, uint256 originBlock, uint256 originTxHash)",
  "event Forwarded(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId, uint8 status, uint256 price, uint24 feePips, uint24 halfRangeBps, bool wantAck)",
  "event Filtered(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId)",
  "event VenueAcked(bytes32 indexed marketId, uint64 indexed seq, uint256 indexed venueId, uint8 status)",
  "event LoopClosed(bytes32 indexed marketId, uint64 indexed seq)",
  "event Ignored(uint256 indexed reason, uint256 chainId, address emitter, uint256 txHash)",
  "function markets(bytes32 marketId) view returns (uint8 status, uint64 seq, uint64 sourceTime, uint112 price)",
  "function inSync(bytes32 marketId) view returns (bool)",
  "function venueCount() view returns (uint256)",
  "function ackMode() view returns (uint8)",
  "function setAckMode(uint8 mode)",
]);

export const vaultAbi = parseAbi([
  "event Repositioned(uint256 price, uint24 halfRangeBps, int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96)",
  "function poolPrice() view returns (uint256)",
  "function valueAt(uint256 price) view returns (uint256)",
  "function holdings() view returns (uint256 stock, uint256 dollars)",
  "function liquidity() view returns (uint128)",
]);

export const arenaAbi = parseAbi([
  "event Raid(address indexed player, uint256 indexed targetId, bool soldStock, uint256 amountIn, uint256 amountOut, int256 pnl, uint256 poolPriceBefore, uint256 refPrice)",
  "event RaidBlocked(address indexed player, uint256 indexed targetId)",
  "event Refilled(uint256 indexed targetId, uint256 stock, uint256 dollars)",
  "event RaidPointless(address indexed player, uint256 indexed targetId, uint256 poolPrice, uint256 refPrice)",
  "function raid(uint256 targetId) returns (int256 pnl)",
  "function scout(uint256 targetId) view returns (uint256 poolPrice, uint256 refPrice, bool tradable, uint24 feePips)",
  "function loot(address player) view returns (int256)",
  "function taken(uint256 targetId) view returns (int256)",
  "function raids(uint256 targetId) view returns (uint256)",
  "function blocked(uint256 targetId) view returns (uint256)",
]);

/** The parts of Reactive Network's system contract that the tools touch. */
export const systemAbi = parseAbi([
  "struct LogRecord { uint256 chainId; address contractAddress; uint256 topic0; uint256 topic1; uint256 topic2; uint256 topic3; bytes data; uint256 blockNumber; uint256 opCode; uint256 blockHash; uint256 txHash; uint256 logIndex; }",
  "function trigger(address contract_, LogRecord log_)",
  "function debt(address contract_) view returns (uint256)",
  "function reserves(address contract_) view returns (uint256)",
  "function depositTo(address contract_) payable",
  "event CallbackRequest(uint256 indexed chainId_, address indexed sender_, address indexed recipient_, uint8 version_, bytes configuration_)",
  "event ReactiveContractReverted(address indexed reactive_, LogRecord log_, bytes error_)",
]);

/** The parts of a destination chain's callback proxy that the tools touch. */
export const proxyAbi = parseAbi([
  "function deliverCallback(uint8 version_, bytes config_)",
  "function debt(address contract_) view returns (uint256)",
  "function reserves(address contract_) view returns (uint256)",
  "function depositTo(address contract_) payable",
  "event CallbackFailure(address indexed target_, bytes payload_)",
]);

export const STATUS = ["CLOSED", "OPEN", "HALTED"] as const;

/** Event signatures the tools filter on. */
export const TOPIC = {
  marketUpdate: toEventSelector("MarketUpdate(bytes32,uint8,uint256,uint64,uint64)"),
  ack: toEventSelector("Ack(bytes32,uint64,uint8)"),
  applied: toEventSelector("Applied(bytes32,uint64,uint8,uint256,uint24,uint24,uint256,uint256)"),
  callbackFailure: toEventSelector("CallbackFailure(address,bytes)"),
} as const;
