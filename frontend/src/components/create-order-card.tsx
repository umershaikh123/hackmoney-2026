"use client"

import { useState, useEffect, useRef } from "react"
import {
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
  useReadContract,
} from "wagmi"
import {
  parseUnits,
  formatUnits,
  keccak256,
  encodeAbiParameters,
  encodePacked,
} from "viem"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { erc20Abi, ghostVaultAbi } from "@/lib/abi"
import {
  GHOST_VAULT_ADDRESS,
  USDC,
  WETH,
  OrderType,
  type OrderTypeName,
} from "@/lib/contracts"
import { useAllowance, useTokenBalance } from "@/hooks/use-ghost-vault"
import { useRevealDataStore } from "@/stores/reveal-data-store"

const POOL_KEY = {
  currency0: WETH,
  currency1: USDC,
  fee: 3000,
  tickSpacing: 60,
  hooks: GHOST_VAULT_ADDRESS,
} as const

export function CreateOrderCard() {
  const { isConnected, address } = useAccount()
  const setReveal = useRevealDataStore(state => state.setReveal)
  const linkOrderId = useRevealDataStore(state => state.linkOrderId)
  const [orderType, setOrderType] = useState<OrderTypeName>("YIELD_ORDER")
  const [amount, setAmount] = useState("1000")
  const [targetPrice, setTargetPrice] = useState("2500")
  const [minDelay, setMinDelay] = useState("60")

  const pendingIntentHash = useRef<string | null>(null)
  const pendingOrderId = useRef<bigint | null>(null)

  const { data: nextOrderId, refetch: refetchNextOrderId } = useReadContract({
    address: GHOST_VAULT_ADDRESS,
    abi: ghostVaultAbi,
    functionName: "nextOrderId",
  })

  const parsedAmount = amount ? parseUnits(amount, 6) : 0n
  const isGhostOrder = orderType === "GHOST_ORDER"

  // Balances and allowances
  const { data: balance } = useTokenBalance(USDC)
  const { data: allowance, refetch: refetchAllowance } = useAllowance(
    USDC,
    GHOST_VAULT_ADDRESS,
  )

  const needsApproval =
    parsedAmount > 0n && (allowance === undefined || allowance < parsedAmount)

  // Approve tx
  const {
    writeContract: writeApprove,
    data: approveHash,
    isPending: approvePending,
    reset: resetApprove,
  } = useWriteContract()

  const { isLoading: approveConfirming, isSuccess: approveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveHash })

  // Commit tx
  const {
    writeContract: writeCommit,
    data: commitHash,
    isPending: commitPending,
    reset: resetCommit,
  } = useWriteContract()

  const { isLoading: commitConfirming, isSuccess: commitConfirmed } =
    useWaitForTransactionReceipt({ hash: commitHash })

  // Refetch allowance after approval
  useEffect(() => {
    if (approveConfirmed) {
      refetchAllowance()
    }
  }, [approveConfirmed, refetchAllowance])

  const handleApprove = () => {
    if (!parsedAmount) return
    writeApprove({
      address: USDC,
      abi: erc20Abi,
      functionName: "approve",
      args: [GHOST_VAULT_ADDRESS, parsedAmount],
    })
  }

  const handleCommit = () => {
    if (!parsedAmount) return

    // Generate intent hash
    const salt = keccak256(
      encodePacked(["uint256"], [BigInt(Date.now())]),
    ) as `0x${string}`
    const parsedPrice = isGhostOrder ? 0n : parseUnits(targetPrice || "0", 8)
    const zeroForOne = false
    const intentHash = keccak256(
      encodeAbiParameters(
        [{ type: "uint256" }, { type: "bool" }, { type: "bytes32" }],
        [parsedPrice, zeroForOne, salt],
      ),
    )

    // Store reveal data for later execution
    setReveal(intentHash, { targetPrice: parsedPrice, zeroForOne, salt })

    pendingIntentHash.current = intentHash
    pendingOrderId.current = (nextOrderId as bigint) ?? 0n

    const parsedDelay = isGhostOrder ? BigInt(Number(minDelay || "0")) : 0n

    writeCommit({
      address: GHOST_VAULT_ADDRESS,
      abi: ghostVaultAbi,
      functionName: "commitOrder",
      args: [
        USDC,
        parsedAmount,
        intentHash,
        OrderType[orderType],
        parsedDelay,
        0n,
        POOL_KEY,
      ],
    })
  }

  // Link orderId to intentHash after commit success
  useEffect(() => {
    if (
      commitConfirmed &&
      pendingIntentHash.current !== null &&
      pendingOrderId.current !== null
    ) {
      linkOrderId(pendingOrderId.current.toString(), pendingIntentHash.current)
      pendingIntentHash.current = null
      pendingOrderId.current = null
      refetchNextOrderId()
    }
  }, [commitConfirmed, linkOrderId, refetchNextOrderId])

  const handleReset = () => {
    resetApprove()
    resetCommit()
    refetchAllowance()
  }

  const formattedBalance = balance ? formatUnits(balance, 6) : "0"

  return (
    <Card>
      <CardHeader>
        <CardTitle>Create Order</CardTitle>
        <CardDescription>
          Deposit USDC into GhostVault. Earns yield while waiting.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {/* Order Type Toggle */}
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => setOrderType("YIELD_ORDER")}
            className={`rounded-lg border p-3 text-left text-sm transition-colors ${
              !isGhostOrder
                ? "border-primary bg-primary/10"
                : "border-border hover:border-muted-foreground"
            }`}
          >
            <div className="font-medium">Yield Order</div>
            <div className="text-xs text-muted-foreground">Price-triggered</div>
          </button>
          <button
            type="button"
            onClick={() => setOrderType("GHOST_ORDER")}
            className={`rounded-lg border p-3 text-left text-sm transition-colors ${
              isGhostOrder
                ? "border-primary bg-primary/10"
                : "border-border hover:border-muted-foreground"
            }`}
          >
            <div className="font-medium">Ghost Order</div>
            <div className="text-xs text-muted-foreground">Time-delayed</div>
          </button>
        </div>

        {/* Amount */}
        <div className="space-y-2">
          <Label>Amount (USDC)</Label>
          <Input
            type="number"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            placeholder="1000"
          />
          {isConnected && (
            <p className="text-xs text-muted-foreground">
              Balance: {Number(formattedBalance).toLocaleString()} USDC
            </p>
          )}
        </div>

        {/* Yield Order: Target Price */}
        {!isGhostOrder && (
          <div className="space-y-2">
            <Label>Target Price (USD)</Label>
            <Input
              type="number"
              value={targetPrice}
              onChange={e => setTargetPrice(e.target.value)}
              placeholder="2500"
            />
            <p className="text-xs text-muted-foreground">
              Executes when ETH price ≤ target (buy low)
            </p>
          </div>
        )}

        {/* Ghost Order: Min Delay */}
        {isGhostOrder && (
          <div className="space-y-2">
            <Label>Min Delay (seconds)</Label>
            <Input
              type="number"
              value={minDelay}
              onChange={e => setMinDelay(e.target.value)}
              placeholder="60"
            />
            <p className="text-xs text-muted-foreground">
              Time before order can be executed
            </p>
          </div>
        )}

        {/* Approval Status */}
        {isConnected && parsedAmount > 0n && (
          <div className="rounded-lg border border-border bg-muted/50 p-3 text-sm">
            {approveConfirming ? (
              <div className="flex items-center gap-2">
                <div className="h-2 w-2 animate-pulse rounded-full bg-blue-500" />
                <span>Waiting for approval confirmation...</span>
              </div>
            ) : needsApproval ? (
              <div className="flex items-center gap-2">
                <div className="h-2 w-2 rounded-full bg-yellow-500" />
                <span>Step 1: Approve USDC spending</span>
              </div>
            ) : (
              <div className="flex items-center gap-2">
                <div className="h-2 w-2 rounded-full bg-green-500" />
                <span>USDC approved — ready to commit</span>
              </div>
            )}
          </div>
        )}

        {/* Buttons */}
        <div className="flex gap-2">
          {needsApproval && (
            <Button
              variant="outline"
              className="flex-1"
              onClick={handleApprove}
              disabled={
                !isConnected ||
                approvePending ||
                approveConfirming ||
                !parsedAmount
              }
            >
              {approvePending
                ? "Signing..."
                : approveConfirming
                  ? "Confirming..."
                  : "Approve"}
            </Button>
          )}
          <Button
            className="flex-1"
            onClick={handleCommit}
            disabled={
              !isConnected ||
              commitPending ||
              commitConfirming ||
              needsApproval ||
              !parsedAmount
            }
          >
            {commitPending
              ? "Signing..."
              : commitConfirming
                ? "Confirming..."
                : `Commit ${isGhostOrder ? "Ghost" : "Yield"} Order`}
          </Button>
        </div>

        {/* Success Messages */}
        {approveConfirmed && !commitConfirmed && (
          <p className="text-center text-sm text-green-500">
            Approved! Now click Commit.
          </p>
        )}
        {commitConfirmed && (
          <div className="space-y-2">
            <p className="text-center text-sm text-green-500">
              Order committed! Funds deposited to vault.
            </p>
            <Button
              variant="ghost"
              size="sm"
              className="w-full"
              onClick={handleReset}
            >
              Create Another
            </Button>
          </div>
        )}

        {!isConnected && (
          <p className="text-center text-sm text-muted-foreground">
            Connect wallet to create orders
          </p>
        )}
      </CardContent>
    </Card>
  )
}
