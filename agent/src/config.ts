import { type Abi, type Address, defineChain } from "viem"
import { base, baseSepolia } from "viem/chains"
import { erc20Abi } from "viem"
import "dotenv/config"

import ghostVaultAbi from "../ghostVaultAbi.json" with { type: "json" }

export const SOLVER_PRIVATE_KEY = process.env.SOLVER_PRIVATE_KEY as `0x${string}`
export const RPC_URL = process.env.BASE_RPC_URL ?? process.env.BASE_MAINNET_RPC
export const CHAIN_ID = Number(process.env.CHAIN_ID ?? "8453")
export const HOOK_ADDRESS = process.env.HOOK_ADDRESS as Address

if (!SOLVER_PRIVATE_KEY) throw new Error("SOLVER_PRIVATE_KEY not set")
if (!RPC_URL) throw new Error("BASE_RPC_URL not set")
if (!HOOK_ADDRESS) throw new Error("HOOK_ADDRESS not set")

const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
})

export const chain = CHAIN_ID === 31337 ? anvil : CHAIN_ID === 84532 ? baseSepolia : base

export const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS ?? "12000")
export const LOOKBACK_BLOCKS = BigInt(process.env.LOOKBACK_BLOCKS ?? "50000")
export const GAS_PRICE_GWEI = Number(process.env.GAS_PRICE_GWEI ?? "0.001")

export const ADDRESSES = {
  USDC: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address,
  WETH: "0x4200000000000000000000000000000000000006" as Address,
  ETH_USD_FEED: "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70" as Address,
  METAMORPHO_VAULT: "0x236919F11ff9eA9550A4287696C2FC9e18E6e890" as Address,
  POOL_MANAGER: "0x498581fF718922c3f8e6A244956aF099B2652b2b" as Address,
} as const

export const ORACLE_ADDRESS = (process.env.ORACLE_ADDRESS ?? ADDRESSES.ETH_USD_FEED) as Address

export const GHOST_VAULT_ABI = ghostVaultAbi as Abi

export const AGGREGATOR_V3_ABI = [
  {
    name: "latestRoundData",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const satisfies Abi

export const ERC20_ABI = erc20Abi

export const OrderType = {
  YIELD_ORDER: 0,
  GHOST_ORDER: 1,
} as const

export const OrderStatus = {
  ACTIVE: 0,
  EXECUTED: 1,
  CANCELLED: 2,
} as const
