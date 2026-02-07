import { type PublicClient, type WalletClient, type Transport } from "viem"

type AnyPublicClient = PublicClient<Transport, any>

import { GHOST_VAULT_ABI, HOOK_ADDRESS } from "./config.js"
import { type RevealData } from "./listener.js"
import * as log from "./logger.js"

export const GATEWAY_URL = process.env.GATEWAY_URL

export interface ExecutionResult {
  success: boolean
  txHash?: `0x${string}`
  gasUsed?: bigint
  error?: string
}

export async function executeOrder(
  publicClient: AnyPublicClient,
  walletClient: WalletClient,
  orderId: bigint,
  revealData: RevealData
): Promise<ExecutionResult> {
  const orderIdNum = Number(orderId)

  if (GATEWAY_URL) {
    log.execute(orderIdNum, "Routing through x402 gateway", { gateway: GATEWAY_URL })
    return executeViaGateway(orderId, revealData)
  }

  log.execute(orderIdNum, "Submitting tx", {
    target: revealData.targetPrice.toString(),
    zeroForOne: revealData.zeroForOne,
  })

  try {
    const account = walletClient.account
    if (!account) {
      return { success: false, error: "No account configured" }
    }

    const { request } = await publicClient.simulateContract({
      address: HOOK_ADDRESS,
      abi: GHOST_VAULT_ABI,
      functionName: "executeOrder",
      args: [
        orderId,
        {
          targetPrice: revealData.targetPrice,
          zeroForOne: revealData.zeroForOne,
          salt: revealData.salt,
        },
      ],
      account,
    })

    const txHash = await walletClient.writeContract(request)
    log.execute(orderIdNum, "Tx submitted", { txHash })

    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash, confirmations: 1 })
    const success = receipt.status === "success"
    const gasUsed = receipt.gasUsed

    if (success) {
      log.execute(orderIdNum, "Success", { txHash, gasUsed: gasUsed.toString(), block: receipt.blockNumber.toString() })
    } else {
      log.error("Tx reverted", { txHash, gasUsed: gasUsed.toString() }, orderIdNum)
    }

    return { success, txHash, gasUsed }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err)

    let reason = message
    if (message.includes("OrderNotActive")) reason = "Order already executed/cancelled"
    else if (message.includes("HashMismatch")) reason = "Invalid reveal data"
    else if (message.includes("PriceConditionNotMet")) reason = "Price moved away"
    else if (message.includes("DelayNotElapsed")) reason = "Delay not met"
    else if (message.includes("OracleStale")) reason = "Oracle stale"
    else if (message.includes("SlippageExceeded")) reason = "Slippage exceeded"

    log.error("Execution failed", { reason, raw: message }, orderIdNum)
    return { success: false, error: reason }
  }
}

export async function simulateExecution(
  publicClient: AnyPublicClient,
  walletClient: WalletClient,
  orderId: bigint,
  revealData: RevealData
): Promise<{ success: boolean; error?: string }> {
  try {
    const account = walletClient.account
    if (!account) {
      return { success: false, error: "No account configured" }
    }

    await publicClient.simulateContract({
      address: HOOK_ADDRESS,
      abi: GHOST_VAULT_ABI,
      functionName: "executeOrder",
      args: [
        orderId,
        {
          targetPrice: revealData.targetPrice,
          zeroForOne: revealData.zeroForOne,
          salt: revealData.salt,
        },
      ],
      account,
    })

    log.info(`Simulation passed for order ${orderId}`)
    return { success: true }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err)
    log.info(`Simulation failed for order ${orderId}: ${message}`)
    return { success: false, error: message }
  }
}

export async function executeViaGateway(orderId: bigint, revealData: RevealData): Promise<ExecutionResult> {
  if (!GATEWAY_URL) {
    log.info("GATEWAY_URL not set")
    return { success: false, error: "GATEWAY_URL not configured" }
  }

  const orderIdNum = Number(orderId)

  try {
    log.execute(orderIdNum, "Requesting payment challenge", { gateway: GATEWAY_URL })

    const challengeRes = await fetch(`${GATEWAY_URL}/execute`, {
      method: "GET",
      headers: { Accept: "application/json" },
    })

    if (challengeRes.status === 402) {
      log.execute(orderIdNum, "Got 402 challenge")
    }

    log.execute(orderIdNum, "Sending execution request")

    const execRes = await fetch(`${GATEWAY_URL}/execute`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        orderId: orderId.toString(),
        revealData: {
          targetPrice: revealData.targetPrice.toString(),
          zeroForOne: revealData.zeroForOne,
          salt: revealData.salt,
        },
      }),
    })

    const result = (await execRes.json()) as {
      success: boolean
      txHash?: string
      gasUsed?: string
      error?: string
    }

    if (result.success) {
      log.execute(orderIdNum, "Gateway success", { txHash: result.txHash, gasUsed: result.gasUsed })
      return {
        success: true,
        txHash: result.txHash as `0x${string}`,
        gasUsed: result.gasUsed ? BigInt(result.gasUsed) : undefined,
      }
    } else {
      log.error("Gateway failed", { error: result.error }, orderIdNum)
      return { success: false, error: result.error }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error("Gateway request failed", { err: message }, orderIdNum)
    return { success: false, error: `Gateway error: ${message}` }
  }
}
