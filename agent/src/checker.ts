import { type PublicClient, type Transport, formatUnits } from "viem"

type AnyPublicClient = PublicClient<Transport, any>

import {
  GHOST_VAULT_ABI,
  AGGREGATOR_V3_ABI,
  HOOK_ADDRESS,
  ORACLE_ADDRESS,
  GAS_PRICE_GWEI,
  OrderType,
} from "./config.js"
import { type TrackedOrder, type RevealData, getRevealData } from "./listener.js"
import * as log from "./logger.js"

export interface CheckResult {
  ready: boolean
  reason: string
  oraclePrice?: bigint
  yieldAccrued?: bigint
  estimatedProfit?: bigint
  revealData?: RevealData
}

interface OracleData {
  price: bigint
  updatedAt: bigint
  fresh: boolean
}

export async function fetchOraclePrice(client: AnyPublicClient): Promise<OracleData> {
  const [, answer, , updatedAt] = (await client.readContract({
    address: ORACLE_ADDRESS,
    abi: AGGREGATOR_V3_ABI,
    functionName: "latestRoundData",
  })) as [bigint, bigint, bigint, bigint, bigint]

  const block = await client.getBlock({ blockTag: "latest" })
  const age = block.timestamp - updatedAt
  const fresh = age <= 3600n

  return { price: answer, updatedAt, fresh }
}

export async function fetchOrderValue(
  client: AnyPublicClient,
  orderId: bigint
): Promise<{ currentValue: bigint; yieldAccrued: bigint }> {
  const [currentValue, yieldAccrued] = (await client.readContract({
    address: HOOK_ADDRESS,
    abi: GHOST_VAULT_ABI,
    functionName: "getOrderValue",
    args: [orderId],
  })) as [bigint, bigint]

  return { currentValue, yieldAccrued }
}

export async function checkOrder(client: AnyPublicClient, order: TrackedOrder): Promise<CheckResult> {
  const orderId = Number(order.orderId)
  const reveal = order.revealData ?? getRevealData(order.orderId)

  if (!reveal) {
    return { ready: false, reason: "No reveal data" }
  }

  const { yieldAccrued } = await fetchOrderValue(client, order.orderId)

  if (order.orderType === OrderType.YIELD_ORDER) {
    const oracle = await fetchOraclePrice(client)

    if (!oracle.fresh) {
      log.skip(orderId, "Oracle stale", { updatedAt: oracle.updatedAt.toString() })
      return { ready: false, reason: "Oracle stale", oraclePrice: oracle.price }
    }

    const priceMet = reveal.zeroForOne
      ? oracle.price >= reveal.targetPrice
      : oracle.price <= reveal.targetPrice

    if (!priceMet) {
      log.skip(orderId, "Price condition not met", {
        current: oracle.price.toString(),
        target: reveal.targetPrice.toString(),
        zeroForOne: reveal.zeroForOne,
      })
      return {
        ready: false,
        reason: `Price ${formatUnits(oracle.price, 8)} vs target ${formatUnits(reveal.targetPrice, 8)}`,
        oraclePrice: oracle.price,
        yieldAccrued,
      }
    }

    log.decision(orderId, "Price condition met", {
      price: formatUnits(oracle.price, 8),
      target: formatUnits(reveal.targetPrice, 8),
      yield: formatUnits(yieldAccrued, 6),
    })

    return {
      ready: true,
      reason: "Price condition met",
      oraclePrice: oracle.price,
      yieldAccrued,
      revealData: reveal,
    }
  }

  if (order.orderType === OrderType.GHOST_ORDER) {
    const block = await client.getBlock({ blockTag: "latest" })
    const elapsed = block.timestamp - order.createdAt
    const delayMet = elapsed >= order.minDelay

    if (!delayMet) {
      const remaining = order.minDelay - elapsed
      log.skip(orderId, "Delay not elapsed", {
        elapsed: elapsed.toString(),
        minDelay: order.minDelay.toString(),
        remaining: remaining.toString(),
      })
      return { ready: false, reason: `Delay: ${elapsed}s / ${order.minDelay}s`, yieldAccrued }
    }

    log.decision(orderId, "Delay elapsed", {
      elapsed: elapsed.toString(),
      minDelay: order.minDelay.toString(),
      yield: formatUnits(yieldAccrued, 6),
    })

    return { ready: true, reason: "Time delay met", yieldAccrued, revealData: reveal }
  }

  return { ready: false, reason: "Unknown order type" }
}

export async function isProfitable(
  client: AnyPublicClient,
  order: TrackedOrder,
  yieldAccrued: bigint
): Promise<{ profitable: boolean; solverFee: bigint; estimatedGasCost: bigint }> {
  const GAS_REIMBURSEMENT = 100_000n
  const MIN_YIELD = 100_000n
  const profitShare = yieldAccrued / 100n

  const solverFee = yieldAccrued >= MIN_YIELD ? GAS_REIMBURSEMENT + profitShare : profitShare

  const gasPriceWei = BigInt(Math.floor(GAS_PRICE_GWEI * 1e9))
  const estimatedGas = 300_000n
  const gasCostWei = gasPriceWei * estimatedGas

  const oracle = await fetchOraclePrice(client)
  const gasCostUSDC = (gasCostWei * oracle.price) / 10n ** 20n

  const profitable = solverFee > gasCostUSDC

  log.decision(Number(order.orderId), "Profitability check", {
    solverFee: formatUnits(solverFee, 6) + " USDC",
    gasCost: formatUnits(gasCostUSDC, 6) + " USDC",
    profitable,
  })

  return { profitable, solverFee, estimatedGasCost: gasCostUSDC }
}
