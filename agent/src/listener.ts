import { type PublicClient, type Address, type Transport } from "viem"

type AnyPublicClient = PublicClient<Transport, any>

import { GHOST_VAULT_ABI, HOOK_ADDRESS, LOOKBACK_BLOCKS, OrderStatus } from "./config.js"
import * as log from "./logger.js"

export interface RevealData {
  targetPrice: bigint
  zeroForOne: boolean
  salt: `0x${string}`
}

export interface TrackedOrder {
  orderId: bigint
  owner: Address
  orderType: number
  tokenIn: Address
  amountIn: bigint
  vaultShares: bigint
  intentHash: `0x${string}`
  createdAt: bigint
  minDelay: bigint
  minAmountOut: bigint
  revealData?: RevealData
}

const revealStore = new Map<string, RevealData>()

export function storeRevealData(orderId: bigint, data: RevealData) {
  revealStore.set(orderId.toString(), data)
}

export function getRevealData(orderId: bigint): RevealData | undefined {
  return revealStore.get(orderId.toString())
}

const activeOrders = new Map<string, TrackedOrder>()

export function getActiveOrders(): TrackedOrder[] {
  return Array.from(activeOrders.values())
}

export function removeOrder(orderId: bigint) {
  activeOrders.delete(orderId.toString())
}

async function fetchOrderDetails(client: AnyPublicClient, orderId: bigint): Promise<TrackedOrder | null> {
  try {
    const result = (await client.readContract({
      address: HOOK_ADDRESS,
      abi: GHOST_VAULT_ABI,
      functionName: "orders",
      args: [orderId],
    })) as readonly [
      Address,
      number,
      number,
      Address,
      Address,
      bigint,
      bigint,
      `0x${string}`,
      bigint,
      bigint,
      bigint,
      { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address },
    ]

    const [owner, orderType, status, tokenIn, , amountIn, vaultShares, intentHash, createdAt, minDelay, minAmountOut] =
      result

    if (status !== OrderStatus.ACTIVE) return null

    return {
      orderId,
      owner,
      orderType,
      tokenIn,
      amountIn,
      vaultShares,
      intentHash,
      createdAt,
      minDelay,
      minAmountOut,
      revealData: getRevealData(orderId),
    }
  } catch (err) {
    log.error("Failed to fetch order", { orderId: orderId.toString(), err: String(err) })
    return null
  }
}

export async function scanHistoricalOrders(client: AnyPublicClient): Promise<number> {
  const currentBlock = await client.getBlockNumber()
  const fromBlock = currentBlock > LOOKBACK_BLOCKS ? currentBlock - LOOKBACK_BLOCKS : 0n

  log.info("Scanning for orders", { fromBlock: fromBlock.toString(), toBlock: currentBlock.toString() })

  const logs = await client.getLogs({
    address: HOOK_ADDRESS,
    event: {
      type: "event",
      name: "OrderCommitted",
      inputs: [
        { name: "orderId", type: "uint256", indexed: true },
        { name: "owner", type: "address", indexed: true },
        { name: "orderType", type: "uint8", indexed: false },
        { name: "tokenIn", type: "address", indexed: false },
        { name: "amountIn", type: "uint256", indexed: false },
        { name: "vaultShares", type: "uint256", indexed: false },
        { name: "intentHash", type: "bytes32", indexed: false },
      ],
    },
    fromBlock,
    toBlock: currentBlock,
  })

  let added = 0
  for (const entry of logs) {
    const args = entry.args
    if (!args || args.orderId === undefined) continue

    const orderId = args.orderId
    const order = await fetchOrderDetails(client, orderId)
    if (order) {
      activeOrders.set(orderId.toString(), order)
      added++
    }
  }

  log.info("Scan complete", { found: logs.length, active: added })
  return added
}

export function watchNewOrders(client: AnyPublicClient): () => void {
  log.info("Watching for new orders")

  const unwatch = client.watchContractEvent({
    address: HOOK_ADDRESS,
    abi: GHOST_VAULT_ABI,
    eventName: "OrderCommitted",
    onLogs: async (logs) => {
      for (const entry of logs) {
        const args = entry.args
        if (!args || !("orderId" in args)) continue
        const orderId = args.orderId as bigint

        log.info("New order detected", { orderId: orderId.toString(), owner: (args as { owner?: string }).owner })

        const order = await fetchOrderDetails(client, orderId)
        if (order) {
          activeOrders.set(orderId.toString(), order)
        }
      }
    },
  })

  const unwatchExecuted = client.watchContractEvent({
    address: HOOK_ADDRESS,
    abi: GHOST_VAULT_ABI,
    eventName: "OrderExecuted",
    onLogs: (logs) => {
      for (const entry of logs) {
        const args = entry.args
        if (args && "orderId" in args) {
          const orderId = (args as { orderId: bigint }).orderId
          log.info("Order executed", { orderId: orderId.toString() })
          removeOrder(orderId)
        }
      }
    },
  })

  const unwatchCancelled = client.watchContractEvent({
    address: HOOK_ADDRESS,
    abi: GHOST_VAULT_ABI,
    eventName: "OrderCancelled",
    onLogs: (logs) => {
      for (const entry of logs) {
        const args = entry.args
        if (args && "orderId" in args) {
          const orderId = (args as { orderId: bigint }).orderId
          log.info("Order cancelled", { orderId: orderId.toString() })
          removeOrder(orderId)
        }
      }
    },
  })

  return () => {
    unwatch()
    unwatchExecuted()
    unwatchCancelled()
  }
}
