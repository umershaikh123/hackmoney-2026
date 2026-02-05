import type { Address } from "viem";

// Deployed GhostVaultHookV2 address — set via env or update after deploy to Anvil fork
export const GHOST_VAULT_ADDRESS: Address =
  (process.env.NEXT_PUBLIC_GHOST_VAULT_ADDRESS as Address) ??
  "0x0000000000000000000000000000000000000000";

// Base mainnet token addresses (available on Anvil fork)
export const USDC: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
export const WETH: Address = "0x4200000000000000000000000000000000000006";

// Order types matching the contract enum
export const OrderType = {
  YIELD_ORDER: 0,
  GHOST_ORDER: 1,
} as const;

export type OrderTypeName = keyof typeof OrderType;

export const ORDER_TYPE_LABELS: Record<number, string> = {
  [OrderType.YIELD_ORDER]: "Yield Order",
  [OrderType.GHOST_ORDER]: "Ghost Order",
};

// OrderStatus enum from contract
export const OrderStatus = {
  ACTIVE: 0,
  EXECUTED: 1,
  CANCELLED: 2,
} as const;

export const ORDER_STATUS_LABELS: Record<number, string> = {
  [OrderStatus.ACTIVE]: "Active",
  [OrderStatus.EXECUTED]: "Executed",
  [OrderStatus.CANCELLED]: "Cancelled",
};

export const TOKEN_OPTIONS = [
  { address: USDC, symbol: "USDC", decimals: 6 },
  { address: WETH, symbol: "WETH", decimals: 18 },
] as const;

// Default PoolKey for USDC/WETH — update hooks address after deploy
// On Base mainnet: WETH (0x4200...) < USDC (0x8335...) so currency0=WETH, currency1=USDC
export const DEFAULT_POOL_KEY = {
  currency0: WETH,
  currency1: USDC,
  fee: 3000,
  tickSpacing: 60,
  hooks: GHOST_VAULT_ADDRESS,
} as const;
