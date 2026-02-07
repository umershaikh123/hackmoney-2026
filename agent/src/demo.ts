import { createPublicClient, createWalletClient, http } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { SOLVER_PRIVATE_KEY, RPC_URL, HOOK_ADDRESS, GHOST_VAULT_ABI, chain } from "./config.js"
import { scanHistoricalOrders, getActiveOrders, storeRevealData } from "./listener.js"
import { checkOrder, isProfitable, fetchOraclePrice } from "./checker.js"
import { executeOrder, simulateExecution } from "./executor.js"
import * as log from "./logger.js"
import { readFileSync, existsSync } from "fs"
import { resolve } from "path"

const args = process.argv.slice(2)
const dryRun = args.includes("--dry-run")
const orderIdArg = args.find((_, i) => args[i - 1] === "--order")
const specificOrderId = orderIdArg ? BigInt(orderIdArg) : undefined

function loadRevealData() {
  const revealPath = resolve(process.cwd(), "reveal-data.json")
  if (!existsSync(revealPath)) {
    log.info("No reveal-data.json found")
    return
  }

  try {
    const raw = readFileSync(revealPath, "utf-8")
    const data = JSON.parse(raw) as Record<string, { targetPrice: string; zeroForOne: boolean; salt: string }>

    for (const [id, reveal] of Object.entries(data)) {
      storeRevealData(BigInt(id), {
        targetPrice: BigInt(reveal.targetPrice),
        zeroForOne: reveal.zeroForOne,
        salt: reveal.salt as `0x${string}`,
      })
    }

    log.info(`Loaded ${Object.keys(data).length} reveal entries`, { file: revealPath })
  } catch (err) {
    log.error("Failed to parse reveal-data.json", { err: String(err) })
  }
}

async function main() {
  console.log("\n  GhostVault Solver — Demo Mode\n")

  log.info(`Hook: ${HOOK_ADDRESS}`)
  log.info(`Chain: ${chain.name} (${chain.id})`)
  log.info(`Dry run: ${dryRun}`)

  const account = privateKeyToAccount(SOLVER_PRIVATE_KEY)
  log.info(`Solver: ${account.address}`)

  const publicClient = createPublicClient({ chain, transport: http(RPC_URL) })
  const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) })

  loadRevealData()

  const oracle = await fetchOraclePrice(publicClient)
  log.info(`ETH/USD: $${Number(oracle.price) / 1e8} (fresh: ${oracle.fresh})`)

  await scanHistoricalOrders(publicClient)
  let orders = getActiveOrders()

  if (specificOrderId !== undefined) {
    orders = orders.filter((o) => o.orderId === specificOrderId)
    if (orders.length === 0) {
      log.info(`Order ${specificOrderId} not found or not active`)
    }
  }

  if (orders.length === 0) {
    log.info("No active orders")

    const nextId = (await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: GHOST_VAULT_ABI,
      functionName: "nextOrderId",
    })) as bigint

    log.info(`Total orders created: ${nextId}`)
    return
  }

  log.info(`Processing ${orders.length} order(s)\n`)

  for (const order of orders) {
    const id = Number(order.orderId)
    const typeName = order.orderType === 0 ? "Yield" : "Ghost"
    log.info(`Checking #${id} (${typeName})`, { owner: order.owner, amount: order.amountIn.toString() })

    const result = await checkOrder(publicClient, order)

    if (!result.ready) {
      log.skip(id, result.reason)
      continue
    }

    if (result.yieldAccrued !== undefined) {
      const profit = await isProfitable(publicClient, order, result.yieldAccrued)
      if (!profit.profitable) {
        log.skip(id, "Not profitable", { fee: profit.solverFee.toString(), gas: profit.estimatedGasCost.toString() })
        log.info("Demo: executing anyway")
      }
    }

    if (!result.revealData) {
      log.skip(id, "No reveal data")
      continue
    }

    if (dryRun) {
      log.info(`[DRY] Simulating #${id}`)
      const sim = await simulateExecution(publicClient, walletClient, order.orderId, result.revealData)
      if (sim.success) {
        log.execute(id, "[DRY] Would execute")
      } else {
        log.error("[DRY] Simulation failed", { error: sim.error }, id)
      }
    } else {
      log.execute(id, "Executing...")
      const execResult = await executeOrder(publicClient, walletClient, order.orderId, result.revealData)
      if (execResult.success) {
        log.execute(id, "Done", { txHash: execResult.txHash, gas: execResult.gasUsed?.toString() })
      }
    }
  }

  console.log("\nDemo complete\n")
}

main().catch((err) => {
  log.error("Fatal", { err: String(err) })
  process.exit(1)
})
