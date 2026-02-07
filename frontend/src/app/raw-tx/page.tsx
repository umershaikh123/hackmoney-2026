"use client"

import { useState } from "react"
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
} from "wagmi"
import { parseUnits, keccak256, encodeAbiParameters, encodePacked } from "viem"
import { ConnectButton } from "@rainbow-me/rainbowkit"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { erc20Abi } from "@/lib/abi"
import { ghostVaultAbi } from "@/lib/abi"

// Hardcoded addresses from cast commands
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const
const WETH = "0x4200000000000000000000000000000000000006" as const
const HOOK = "0x0DA88c243E294861ae094Bf74A3689b6764980c0" as const

const AMOUNT = parseUnits("1000", 6) // 1000 USDC

// Pool key struct
const POOL_KEY = {
  currency0: WETH,
  currency1: USDC,
  fee: 3000,
  tickSpacing: 60,
  hooks: HOOK,
} as const

export default function RawTxPage() {
  const { isConnected } = useAccount()
  const [logs, setLogs] = useState<string[]>([])

  const addLog = (msg: string) => {
    setLogs(prev => [...prev, `[${new Date().toLocaleTimeString()}] ${msg}`])
  }

  // Approve tx
  const {
    writeContract: writeApprove,
    data: approveHash,
    isPending: approvePending,
  } = useWriteContract()

  const { isLoading: approveConfirming, isSuccess: approveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveHash })

  // Commit tx
  const {
    writeContract: writeCommit,
    data: commitHash,
    isPending: commitPending,
  } = useWriteContract()

  const { isLoading: commitConfirming, isSuccess: commitConfirmed } =
    useWaitForTransactionReceipt({ hash: commitHash })

  const handleApprove = () => {
    addLog(`Approving ${AMOUNT.toString()} USDC to ${HOOK}...`)
    writeApprove(
      {
        address: USDC,
        abi: erc20Abi,
        functionName: "approve",
        args: [HOOK, AMOUNT],
      },
      {
        onSuccess: hash => addLog(`Approve tx sent: ${hash}`),
        onError: err => addLog(`Approve error: ${err.message}`),
      },
    )
  }

  const handleCommit = () => {
    // Generate intent hash
    const salt = keccak256(encodePacked(["uint256"], [BigInt(Date.now())]))
    const targetPrice = 0n // Ghost order - no price target
    const zeroForOne = false
    const intentHash = keccak256(
      encodeAbiParameters(
        [{ type: "uint256" }, { type: "bool" }, { type: "bytes32" }],
        [targetPrice, zeroForOne, salt],
      ),
    )

    addLog(`Committing order: ${AMOUNT.toString()} USDC`)
    addLog(`Intent hash: ${intentHash}`)

    writeCommit(
      {
        address: HOOK,
        abi: ghostVaultAbi,
        functionName: "commitOrder",
        args: [
          USDC, // tokenIn
          AMOUNT, // amountIn
          intentHash, // intentHash
          0, // orderType (0 = YIELD_ORDER)
          0n, // minDelay
          0n, // minAmountOut
          POOL_KEY, // poolKey tuple
        ],
      },
      {
        onSuccess: hash => addLog(`Commit tx sent: ${hash}`),
        onError: err => addLog(`Commit error: ${err.message}`),
      },
    )
  }

  return (
    <main className="min-h-screen bg-background p-8">
      <div className="mx-auto max-w-2xl space-y-6">
        <div className="flex items-center justify-between">
          <h1 className="text-2xl font-bold">Raw TX Test</h1>
          <ConnectButton />
        </div>

        <Card>
          <CardHeader>
            <CardTitle>Simple Wagmi TX Test</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="rounded bg-muted p-3 text-sm font-mono">
              <p>USDC: {USDC}</p>
              <p>HOOK: {HOOK}</p>
              <p>Amount: 1000 USDC</p>
            </div>

            <div className="flex gap-4">
              <Button
                onClick={handleApprove}
                disabled={!isConnected || approvePending || approveConfirming}
                variant="outline"
              >
                {approvePending
                  ? "Signing..."
                  : approveConfirming
                    ? "Confirming..."
                    : "1. Approve"}
              </Button>

              <Button
                onClick={handleCommit}
                disabled={!isConnected || commitPending || commitConfirming}
              >
                {commitPending
                  ? "Signing..."
                  : commitConfirming
                    ? "Confirming..."
                    : "2. Commit Order"}
              </Button>
            </div>

            {approveConfirmed && (
              <p className="text-sm text-green-500">Approve confirmed</p>
            )}
            {commitConfirmed && (
              <p className="text-sm text-green-500">Commit confirmed</p>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Logs</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="h-64 overflow-y-auto rounded bg-black p-3 font-mono text-xs text-green-400">
              {logs.length === 0 ? (
                <p className="text-muted-foreground">No logs yet...</p>
              ) : (
                logs.map((log, i) => <p key={i}>{log}</p>)
              )}
            </div>
          </CardContent>
        </Card>
      </div>
    </main>
  )
}
