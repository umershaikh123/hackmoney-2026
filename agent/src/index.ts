import { createPublicClient, createWalletClient, http, formatUnits } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import { SOLVER_PRIVATE_KEY, RPC_URL, HOOK_ADDRESS, ORACLE_ADDRESS, POLL_INTERVAL_MS, chain } from "./config.js"
import { scanHistoricalOrders, getActiveOrders, removeOrder, watchNewOrders, storeRevealData } from "./listener.js"
import { checkOrder, isProfitable, fetchOraclePrice } from "./checker.js"
import { executeOrder, simulateExecution } from "./executor.js"
import * as log from "./logger.js"
import { readFileSync, existsSync, watchFile } from "fs"
import { resolve } from "path"

const dryRun = process.argv.includes("--dry-run")
const REVEAL_PATH = resolve(process.cwd(), "reveal-data.json")

function loadRevealData() {
  if (!existsSync(REVEAL_PATH)) return

  try {
    const raw = readFileSync(REVEAL_PATH, "utf-8")
    const data = JSON.parse(raw) as Record<string, { targetPrice: string; zeroForOne: boolean; salt: string }>

    for (const [id, reveal] of Object.entries(data)) {
      storeRevealData(BigInt(id), {
        targetPrice: BigInt(reveal.targetPrice),
        zeroForOne: reveal.zeroForOne,
        salt: reveal.salt as `0x${string}`,
      })
    }

    log.info(`Loaded ${Object.keys(data).length} reveal entries`)
  } catch (err) {
    log.error("Failed to load reveal-data.json", { err: String(err) })
  }
}

let loopCount = 0

async function monitoringLoop(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>
) {
  loopCount++
  const orders = getActiveOrders()

  if (orders.length === 0) {
    if (loopCount % 5 === 0) {
      log.info("Waiting for orders...", { cycle: loopCount })
    }
    return
  }

  log.info(`Cycle ${loopCount}: checking ${orders.length} order(s)`)

  for (const order of orders) {
    const id = Number(order.orderId)

    try {
      const result = await checkOrder(publicClient, order)
      if (!result.ready) continue

      if (result.yieldAccrued !== undefined && result.yieldAccrued > 0n) {
        const profit = await isProfitable(publicClient, order, result.yieldAccrued)
        if (!profit.profitable) {
          log.skip(id, "Not profitable", {
            fee: formatUnits(profit.solverFee, 6) + " USDC",
            gas: formatUnits(profit.estimatedGasCost, 6) + " USDC",
          })
          continue
        }
      }

      if (!result.revealData) {
        log.skip(id, "Missing reveal data")
        continue
      }

      if (dryRun) {
        const sim = await simulateExecution(publicClient, walletClient, order.orderId, result.revealData)
        log.info(`[DRY] Order #${id}: ${sim.success ? "PASS" : "FAIL"}`)
      } else {
        const execResult = await executeOrder(publicClient, walletClient, order.orderId, result.revealData)
        if (execResult.success) {
          removeOrder(order.orderId)
        }
      }
    } catch (err) {
      log.error("Check failed", { orderId: id, err: String(err) })
    }
  }
}

async function main() {
  console.log("\n  GhostVault Solver Agent\n")

  log.info(`Hook: ${HOOK_ADDRESS}`)
  log.info(`Oracle: ${ORACLE_ADDRESS}`)
  log.info(`Chain: ${chain.name} (${chain.id})`)
  log.info(`Poll: ${POLL_INTERVAL_MS}ms`)
  log.info(`Dry run: ${dryRun}`)

  const account = privateKeyToAccount(SOLVER_PRIVATE_KEY)
  log.info(`Solver: ${account.address}`)

  const publicClient = createPublicClient({ chain, transport: http(RPC_URL) })
  const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) })

  loadRevealData()

  if (existsSync(REVEAL_PATH)) {
    watchFile(REVEAL_PATH, { interval: 5000 }, () => {
      log.info("reveal-data.json changed, reloading")
      loadRevealData()
    })
  }

  const oracle = await fetchOraclePrice(publicClient)
  log.info(`ETH/USD: $${Number(oracle.price) / 1e8} (fresh: ${oracle.fresh})`)

  await scanHistoricalOrders(publicClient)

  const stopWatching = watchNewOrders(publicClient)

  log.info("Monitoring started. Ctrl+C to stop.\n")

  const interval = setInterval(async () => {
    try {
      await monitoringLoop(publicClient, walletClient)
    } catch (err) {
      log.error("Loop error", { err: String(err) })
    }
  }, POLL_INTERVAL_MS)

  const shutdown = () => {
    log.info("Shutting down...")
    clearInterval(interval)
    stopWatching()
    process.exit(0)
  }

  process.on("SIGINT", shutdown)
  process.on("SIGTERM", shutdown)
}

main().catch((err) => {
  log.error("Fatal", { err: String(err) })
  process.exit(1)
})
