"use client"

import { useState, useEffect, useRef, useMemo } from "react"
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
import { useLogStore } from "@/stores/log-store"

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
  const addLog = useLogStore(state => state.addLog)
  const [orderType, setOrderType] = useState<OrderTypeName>("YIELD_ORDER")
  const [amount, setAmount] = useState("1000")
  const [targetPrice, setTargetPrice] = useState("2500")
  const [minDelay, setMinDelay] = useState("60")
  const [showPrivacyPreview, setShowPrivacyPreview] = useState(false)
  const [previewSalt, setPreviewSalt] = useState<`0x${string}` | null>(null)

  const pendingIntentHash = useRef<string | null>(null)
  const pendingOrderId = useRef<bigint | null>(null)

  const { data: nextOrderId, refetch: refetchNextOrderId } = useReadContract({
    address: GHOST_VAULT_ADDRESS,
    abi: ghostVaultAbi,
    functionName: "nextOrderId",
  })

  const parsedAmount = amount ? parseUnits(amount, 6) : 0n
  const isGhostOrder = orderType === "GHOST_ORDER"

  // Generate preview salt on demand
  const generatePreviewSalt = () => {
    const salt = keccak256(
      encodePacked(["uint256"], [BigInt(Date.now())]),
    ) as `0x${string}`
    setPreviewSalt(salt)
    setShowPrivacyPreview(true)
  }

  // Compute preview intent hash
  const previewIntentData = useMemo(() => {
    if (!previewSalt) return null
    const parsedPrice = isGhostOrder ? 0n : parseUnits(targetPrice || "0", 8)
    const zeroForOne = false
    const intentHash = keccak256(
      encodeAbiParameters(
        [{ type: "uint256" }, { type: "bool" }, { type: "bytes32" }],
        [parsedPrice, zeroForOne, previewSalt],
      ),
    )
    return {
      salt: previewSalt,
      targetPrice: parsedPrice,
      zeroForOne,
      intentHash,
    }
  }, [previewSalt, targetPrice, isGhostOrder])

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
    addLog("info", `Approving ${amount} USDC...`)
    writeApprove({
      address: USDC,
      abi: erc20Abi,
      functionName: "approve",
      args: [GHOST_VAULT_ADDRESS, parsedAmount],
    })
  }

  // Log approve confirmation
  useEffect(() => {
    if (approveHash) {
      addLog("tx", "Approve tx submitted:", approveHash)
    }
  }, [approveHash, addLog])

  useEffect(() => {
    if (approveConfirmed && approveHash) {
      addLog("success", "USDC approved!", approveHash)
    }
  }, [approveConfirmed, approveHash, addLog])

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

    const orderTypeName = isGhostOrder ? "Ghost" : "Yield"
    addLog("info", `Committing ${orderTypeName} Order: ${amount} USDC`)
    addLog("info", `Intent hash: ${intentHash.slice(0, 18)}...`)

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

  // Log commit confirmation
  useEffect(() => {
    if (commitHash) {
      addLog("tx", "Commit tx submitted:", commitHash)
    }
  }, [commitHash, addLog])

  useEffect(() => {
    if (commitConfirmed && commitHash && pendingOrderId.current !== null) {
      addLog("success", `Order #${pendingOrderId.current} created! Funds deposited to vault.`, commitHash)
    }
  }, [commitConfirmed, commitHash, addLog])

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
    setPreviewSalt(null)
    setShowPrivacyPreview(false)
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

        {/* Privacy Preview - Commit-Reveal Visualization */}
        <div className="space-y-2">
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="w-full text-xs text-muted-foreground hover:text-foreground"
            onClick={generatePreviewSalt}
          >
            {showPrivacyPreview ? "Regenerate" : "Preview"} Commit-Reveal Data
          </Button>

          {showPrivacyPreview && previewIntentData && (
            <div className="rounded-lg border border-border bg-muted/30 p-3 space-y-3 text-xs">
              {/* What goes ON-CHAIN */}
              <div className="space-y-1">
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 rounded-full bg-red-500" />
                  <span className="font-medium text-red-400">On-Chain (Public)</span>
                </div>
                <div className="ml-4 space-y-1 font-mono text-muted-foreground">
                  <div className="flex justify-between">
                    <span>intentHash:</span>
                    <span className="text-foreground truncate max-w-[180px]" title={previewIntentData.intentHash}>
                      {previewIntentData.intentHash.slice(0, 10)}...{previewIntentData.intentHash.slice(-8)}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span>amount:</span>
                    <span className="text-foreground">{amount} USDC</span>
                  </div>
                </div>
                <p className="ml-4 text-muted-foreground italic">
                  MEV bots see the hash but can't decode your intent
                </p>
              </div>

              {/* What stays OFF-CHAIN */}
              <div className="space-y-1 border-t border-border pt-2">
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 rounded-full bg-green-500" />
                  <span className="font-medium text-green-400">Off-Chain (Private)</span>
                </div>
                <div className="ml-4 space-y-1 font-mono text-muted-foreground">
                  <div className="flex justify-between">
                    <span>salt:</span>
                    <span className="text-foreground truncate max-w-[180px]" title={previewIntentData.salt}>
                      {previewIntentData.salt.slice(0, 10)}...{previewIntentData.salt.slice(-8)}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span>targetPrice:</span>
                    <span className="text-foreground">
                      {isGhostOrder ? "0 (time-based)" : `$${targetPrice}`}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span>zeroForOne:</span>
                    <span className="text-foreground">false (USDC → WETH)</span>
                  </div>
                </div>
                <p className="ml-4 text-muted-foreground italic">
                  Only you and the solver agent know this data
                </p>
              </div>

              {/* Hash Formula */}
              <div className="border-t border-border pt-2">
                <p className="text-center text-muted-foreground">
                  <span className="font-mono text-primary">intentHash</span> = keccak256(targetPrice, zeroForOne, salt)
                </p>
              </div>
            </div>
          )}
        </div>

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
