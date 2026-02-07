import { createServer, type IncomingMessage, type ServerResponse } from "http"
import { createPublicClient, createWalletClient, http } from "viem"
import { privateKeyToAccount } from "viem/accounts"
import {
  x402HTTPResourceServer,
  x402ResourceServer,
  HTTPFacilitatorClient,
  type HTTPAdapter,
  type HTTPRequestContext,
  type RoutesConfig,
} from "@x402/core/server"
import { createFacilitatorConfig } from "@coinbase/x402"
import { SOLVER_PRIVATE_KEY, RPC_URL, HOOK_ADDRESS, GHOST_VAULT_ABI, chain, CHAIN_ID, OrderStatus } from "./config.js"
import { executeOrder as execOnChain } from "./executor.js"
import * as log from "./logger.js"
import "dotenv/config"

const PORT = Number(process.env.GATEWAY_PORT ?? "4020")
const GATEWAY_FEE = process.env.GATEWAY_FEE ?? "$0.01"

const account = privateKeyToAccount(SOLVER_PRIVATE_KEY)
const publicClient = createPublicClient({ chain, transport: http(RPC_URL) })
const walletClient = createWalletClient({ account, chain, transport: http(RPC_URL) })

const executingOrders = new Set<string>()
const executedOrders = new Map<string, { txHash: string; timestamp: number }>()

function pruneExecutedOrders() {
  const cutoff = Date.now() - 3_600_000
  for (const [id, entry] of executedOrders) {
    if (entry.timestamp < cutoff) executedOrders.delete(id)
  }
}

const RATE_LIMIT_WINDOW_MS = 60_000
const RATE_LIMIT_MAX = 20
const rateLimitBuckets = new Map<string, { count: number; resetAt: number }>()

function checkRateLimit(ip: string): boolean {
  const now = Date.now()
  const bucket = rateLimitBuckets.get(ip)

  if (!bucket || now >= bucket.resetAt) {
    rateLimitBuckets.set(ip, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS })
    return true
  }

  if (bucket.count >= RATE_LIMIT_MAX) return false
  bucket.count++
  return true
}

const EXECUTION_TIMEOUT_MS = 60_000

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error(`${label} timed out`)), ms)),
  ])
}

const network = `eip155:${CHAIN_ID}` as const

const routes: RoutesConfig = {
  "POST /execute": {
    accepts: { scheme: "exact", network, payTo: account.address, price: GATEWAY_FEE },
    description: "Execute a GhostVault order",
    mimeType: "application/json",
    unpaidResponseBody: () => ({
      contentType: "application/json",
      body: { error: "Payment required", docs: "https://github.com/ghostvault/protocol" },
    }),
  },
}

async function createX402Server() {
  const hasCdpCredentials = process.env.CDP_API_KEY_ID && process.env.CDP_API_KEY_SECRET

  if (!hasCdpCredentials) {
    log.info("No CDP credentials — demo mode (no payment verification)")
  }

  try {
    const facilitatorConfig = hasCdpCredentials
      ? createFacilitatorConfig(process.env.CDP_API_KEY_ID, process.env.CDP_API_KEY_SECRET)
      : createFacilitatorConfig()

    const facilitatorClient = new HTTPFacilitatorClient(facilitatorConfig)
    const resourceServer = new x402ResourceServer(facilitatorClient)
    const httpServer = new x402HTTPResourceServer(resourceServer, routes)

    resourceServer.onAfterVerify(async (ctx) => log.info("Payment verified", { network: ctx.requirements.network }))
    resourceServer.onAfterSettle(async (ctx) => log.info("Payment settled", { success: ctx.result.success }))

    await httpServer.initialize()
    return httpServer
  } catch (err) {
    log.info("x402 setup failed — demo mode")
    return null
  }
}

function parseBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on("data", (chunk: Buffer) => chunks.push(chunk))
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString()
        resolve(raw ? JSON.parse(raw) : {})
      } catch {
        resolve({})
      }
    })
    req.on("error", reject)
  })
}

function createHTTPAdapter(req: IncomingMessage): HTTPAdapter {
  return {
    getHeader: (name: string) => (req.headers[name.toLowerCase()] as string) ?? undefined,
    getMethod: () => req.method ?? "GET",
    getPath: () => new URL(req.url ?? "/", `http://localhost:${PORT}`).pathname,
    getUrl: () => `http://localhost:${PORT}${req.url ?? "/"}`,
    getAcceptHeader: () => (req.headers.accept as string) ?? "application/json",
    getUserAgent: () => (req.headers["user-agent"] as string) ?? "",
  }
}

function sendJSON(res: ServerResponse, status: number, body: unknown, headers?: Record<string, string>) {
  const json = JSON.stringify(body)
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json), ...headers })
  res.end(json)
}

interface ExecuteRequestBody {
  orderId: string
  revealData: { targetPrice: string; zeroForOne: boolean; salt: string }
}

async function handleExecute(body: ExecuteRequestBody, res: ServerResponse) {
  const { orderId, revealData } = body

  if (!orderId || !revealData) {
    sendJSON(res, 400, { error: "Missing orderId or revealData" })
    return
  }

  if (!revealData.targetPrice || typeof revealData.zeroForOne !== "boolean" || !revealData.salt?.startsWith("0x")) {
    sendJSON(res, 400, { error: "Invalid revealData format" })
    return
  }

  const orderKey = orderId.toString()
  const prior = executedOrders.get(orderKey)
  if (prior) {
    log.info(`Order ${orderId} already executed — cached`)
    sendJSON(res, 200, { success: true, txHash: prior.txHash, orderId, cached: true })
    return
  }

  if (executingOrders.has(orderKey)) {
    log.info(`Order ${orderId} already in progress`)
    sendJSON(res, 409, { error: "Order execution in progress", orderId })
    return
  }

  try {
    const result = (await publicClient.readContract({
      address: HOOK_ADDRESS,
      abi: GHOST_VAULT_ABI,
      functionName: "getOrder",
      args: [BigInt(orderId)],
    })) as readonly [string, number, number, string, bigint, bigint, string, bigint, bigint]

    if (result[2] !== OrderStatus.ACTIVE) {
      sendJSON(res, 410, { error: "Order not active", orderId, status: result[2] })
      return
    }
  } catch {
    sendJSON(res, 400, { error: "Order not found", orderId })
    return
  }

  executingOrders.add(orderKey)
  log.execute(Number(orderId), "Gateway executing")

  try {
    const result = await withTimeout(
      execOnChain(publicClient, walletClient, BigInt(orderId), {
        targetPrice: BigInt(revealData.targetPrice),
        zeroForOne: revealData.zeroForOne,
        salt: revealData.salt as `0x${string}`,
      }),
      EXECUTION_TIMEOUT_MS,
      `executeOrder(${orderId})`
    )

    if (result.success && result.txHash) {
      executedOrders.set(orderKey, { txHash: result.txHash, timestamp: Date.now() })
      pruneExecutedOrders()
      sendJSON(res, 200, { success: true, txHash: result.txHash, gasUsed: result.gasUsed?.toString(), orderId })
    } else {
      sendJSON(res, 500, { success: false, error: result.error, orderId })
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error("Gateway error", { orderId, err: message })
    sendJSON(res, 500, { success: false, error: message, orderId })
  } finally {
    executingOrders.delete(orderKey)
  }
}

async function main() {
  console.log("\n  GhostVault x402 Gateway\n")

  log.info(`Hook: ${HOOK_ADDRESS}`)
  log.info(`Chain: ${chain.name} (${CHAIN_ID})`)
  log.info(`PayTo: ${account.address}`)
  log.info(`Fee: ${GATEWAY_FEE}`)
  log.info(`Port: ${PORT}`)

  const x402Server = await createX402Server()
  const demoMode = !x402Server

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", `http://localhost:${PORT}`)
    const method = req.method ?? "GET"

    res.setHeader("Access-Control-Allow-Origin", "*")
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, PAYMENT-SIGNATURE, X-PAYMENT, Authorization")
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    if (method === "OPTIONS") {
      res.writeHead(204)
      res.end()
      return
    }

    const clientIP =
      (req.headers["x-forwarded-for"] as string)?.split(",")[0]?.trim() ?? req.socket.remoteAddress ?? "unknown"
    if (!checkRateLimit(clientIP)) {
      sendJSON(res, 429, { error: "Rate limit exceeded", retryAfter: 60 })
      return
    }

    if (url.pathname === "/" || url.pathname === "/health") {
      sendJSON(res, 200, {
        service: "ghostvault-x402-gateway",
        status: "ok",
        hook: HOOK_ADDRESS,
        chain: chain.name,
        chainId: CHAIN_ID,
        fee: GATEWAY_FEE,
        demoMode,
        activeExecutions: executingOrders.size,
      })
      return
    }

    if (url.pathname === "/execute" && method === "POST") {
      const body = (await parseBody(req)) as ExecuteRequestBody

      if (x402Server) {
        const adapter = createHTTPAdapter(req)
        const context: HTTPRequestContext = {
          adapter,
          path: "/execute",
          method: "POST",
          paymentHeader: adapter.getHeader("payment-signature"),
        }

        const result = await x402Server.processHTTPRequest(context)

        if (result.type === "payment-error") {
          const { status, headers, body: errBody } = result.response
          sendJSON(res, status, errBody, {
            ...headers,
            "WWW-Authenticate": `x402 network="${network}", payTo="${account.address}", price="${GATEWAY_FEE}"`,
          })
          return
        }

        if (result.type === "payment-verified") {
          log.info("Payment verified — executing")
          await x402Server.processSettlement(result.paymentPayload, result.paymentRequirements)
        }
      } else {
        log.info("[DEMO] Skipping payment")
      }

      await handleExecute(body, res)
      return
    }

    if (url.pathname === "/execute" && method === "GET") {
      if (x402Server) {
        const adapter = createHTTPAdapter(req)
        const context: HTTPRequestContext = { adapter, path: "/execute", method: "POST" }
        const result = await x402Server.processHTTPRequest(context)
        if (result.type === "payment-error") {
          const { status, headers, body: errBody } = result.response
          sendJSON(res, status, errBody, {
            ...headers,
            "WWW-Authenticate": `x402 network="${network}", payTo="${account.address}", price="${GATEWAY_FEE}"`,
          })
          return
        }
      }

      sendJSON(
        res,
        402,
        {
          error: "Payment Required",
          protocol: "x402",
          network,
          chainId: CHAIN_ID,
          payTo: account.address,
          price: GATEWAY_FEE,
          description: "Pay to execute a GhostVault order",
        },
        { "WWW-Authenticate": `x402 network="${network}", payTo="${account.address}", price="${GATEWAY_FEE}"` }
      )
      return
    }

    sendJSON(res, 404, { error: "Not found" })
  })

  server.listen(PORT, () => {
    log.info(`Listening on http://localhost:${PORT}`)
    log.info("GET  /health  — Health check")
    log.info("GET  /execute — 402 challenge")
    log.info("POST /execute — Execute order")
    if (demoMode) log.info("[DEMO] Payment verification disabled")
    console.log("")
  })
}

main().catch((err) => {
  log.error("Fatal", { err: String(err) })
  process.exit(1)
})
