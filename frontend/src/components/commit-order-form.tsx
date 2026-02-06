"use client"

import { useState, useCallback, useEffect } from "react"
import { parseUnits, keccak256, encodePacked, formatUnits } from "viem"
import { useAccount } from "wagmi"

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
import {
  useCommitOrder,
  useAllowance,
  useApprove,
  useTokenBalance,
} from "@/hooks/use-ghost-vault"
import {
  OrderType,
  TOKEN_OPTIONS,
  GHOST_VAULT_ADDRESS,
  type OrderTypeName,
} from "@/lib/contracts"
import type { Address } from "viem"

const ORDER_TYPE_OPTIONS: {
  value: OrderTypeName
  label: string
  description: string
}[] = [
  {
    value: "YIELD_ORDER",
    label: "Yield Order",
    description: "Price-triggered limit order. Earns yield while waiting.",
  },
  {
    value: "GHOST_ORDER",
    label: "Ghost Order",
    description: "Time-delayed privacy swap. Commit-reveal hides intent.",
  },
]

export function CommitOrderForm() {
  const { isConnected } = useAccount()
  const {
    commitOrder,
    isPending: isCommitPending,
    isSuccess: isCommitSuccess,
  } = useCommitOrder()

  const {
    approve,
    isPending: isApprovePending,
    isSuccess: isApproveSuccess,
    reset: resetApprove,
  } = useApprove()

  const [orderType, setOrderType] = useState<OrderTypeName>("YIELD_ORDER")
  const [tokenIn, setTokenIn] = useState<Address>(TOKEN_OPTIONS[0].address)
  const [amount, setAmount] = useState("")
  const [targetPrice, setTargetPrice] = useState("")
  const [minDelay, setMinDelay] = useState("")

  const selectedToken =
    TOKEN_OPTIONS.find(t => t.address === tokenIn) ?? TOKEN_OPTIONS[0]
  const isGhostOrder = orderType === "GHOST_ORDER"

  // Get current allowance and balance
  const { data: allowance, refetch: refetchAllowance } = useAllowance(
    tokenIn,
    GHOST_VAULT_ADDRESS,
  )
  const { data: balance } = useTokenBalance(tokenIn)

  // Parse amount for comparison
  const parsedAmount = amount
    ? parseUnits(amount, selectedToken.decimals)
    : 0n

  // Check if approval is needed
  const needsApproval =
    parsedAmount > 0n && (allowance === undefined || allowance < parsedAmount)

  // Refetch allowance after approval tx sent
  useEffect(() => {
    if (isApproveSuccess) {
      // Give the tx time to be mined, then refetch
      const timer = setTimeout(() => refetchAllowance(), 2000)
      return () => clearTimeout(timer)
    }
  }, [isApproveSuccess, refetchAllowance])

  // Reset approval state when token or amount changes
  useEffect(() => {
    resetApprove()
  }, [tokenIn, amount, resetApprove])

  const handleApprove = useCallback(() => {
    if (!parsedAmount) return
    approve(tokenIn, GHOST_VAULT_ADDRESS, parsedAmount)
  }, [approve, tokenIn, parsedAmount])

  const handleSubmit = useCallback(
    (e: React.FormEvent) => {
      e.preventDefault()
      if (!amount) return
      if (!isGhostOrder && !targetPrice) return
      if (needsApproval) return // Safety check

      const parsedPrice = targetPrice ? parseUnits(targetPrice, 8) : 0n
      const parsedDelay =
        isGhostOrder && minDelay ? BigInt(Number(minDelay) * 60) : 0n

      // Generate commit-reveal intent hash
      // hash(targetPrice, zeroForOne, salt)
      const salt = keccak256(encodePacked(["uint256"], [BigInt(Date.now())]))
      const zeroForOne = false // selling USDC for WETH on Base (USDC is currency1)
      const intentHash = keccak256(
        encodePacked(
          ["uint256", "bool", "bytes32"],
          [parsedPrice, zeroForOne, salt],
        ),
      )

      commitOrder(
        tokenIn,
        parsedAmount,
        intentHash,
        OrderType[orderType],
        parsedDelay,
        0n, // minAmountOut — set to 0 for demo
      )
    },
    [
      amount,
      targetPrice,
      minDelay,
      tokenIn,
      orderType,
      parsedAmount,
      isGhostOrder,
      needsApproval,
      commitOrder,
    ],
  )

  // Format balance for display
  const formattedBalance = balance
    ? formatUnits(balance, selectedToken.decimals)
    : "0"

  // Button state - simpler: just check if tx is pending
  const isApproving = isApprovePending

  return (
    <Card>
      <CardHeader>
        <CardTitle>Commit Order</CardTitle>
        <CardDescription>
          Deposit tokens into GhostVault. They earn yield in MetaMorpho while
          waiting for execution conditions.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-5">
          {/* Order Type */}
          <div className="space-y-2">
            <Label>Order Type</Label>
            <div className="grid grid-cols-2 gap-2">
              {ORDER_TYPE_OPTIONS.map(opt => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setOrderType(opt.value)}
                  className={`rounded-lg border p-3 text-left text-sm transition-colors ${
                    orderType === opt.value
                      ? "border-primary bg-primary/10 text-foreground"
                      : "border-border bg-card text-muted-foreground hover:border-muted-foreground"
                  }`}
                >
                  <div className="font-medium">{opt.label}</div>
                  <div className="text-xs text-muted-foreground">
                    {opt.description}
                  </div>
                </button>
              ))}
            </div>
          </div>

          {/* Token Select */}
          <div className="space-y-2">
            <Label htmlFor="token">Token</Label>
            <div className="grid grid-cols-2 gap-2">
              {TOKEN_OPTIONS.map(token => (
                <button
                  key={token.address}
                  type="button"
                  onClick={() => setTokenIn(token.address)}
                  className={`rounded-lg border px-4 py-2.5 text-sm font-medium transition-colors ${
                    tokenIn === token.address
                      ? "border-primary bg-primary/10 text-foreground"
                      : "border-border bg-card text-muted-foreground hover:border-muted-foreground"
                  }`}
                >
                  {token.symbol}
                </button>
              ))}
            </div>
            {isConnected && (
              <p className="text-xs text-muted-foreground">
                Balance: {Number(formattedBalance).toLocaleString()}{" "}
                {selectedToken.symbol}
              </p>
            )}
          </div>

          {/* Amount */}
          <div className="space-y-2">
            <Label htmlFor="amount">Amount ({selectedToken.symbol})</Label>
            <Input
              id="amount"
              type="number"
              step="any"
              min="0"
              placeholder={`0.00 ${selectedToken.symbol}`}
              value={amount}
              onChange={e => setAmount(e.target.value)}
            />
          </div>

          {/* Yield Order: Target Price */}
          {!isGhostOrder ? (
            <div className="space-y-2">
              <Label htmlFor="targetPrice">Target Price (USD)</Label>
              <Input
                id="targetPrice"
                type="number"
                step="any"
                min="0"
                placeholder="0.00"
                value={targetPrice}
                onChange={e => setTargetPrice(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Chainlink ETH/USD oracle price (8 decimals). Order executes when
                price condition is met.
              </p>
            </div>
          ) : null}

          {/* Ghost Order: Min Delay */}
          {isGhostOrder ? (
            <div className="space-y-2">
              <Label htmlFor="minDelay">Minimum Delay (minutes)</Label>
              <Input
                id="minDelay"
                type="number"
                step="1"
                min="0"
                placeholder="60"
                value={minDelay}
                onChange={e => setMinDelay(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Time before the order can be executed. Temporal separation
                reduces MEV exposure.
              </p>
            </div>
          ) : null}

          {/* Approval Status */}
          {isConnected && parsedAmount > 0n && (
            <div className="rounded-lg border border-border bg-muted/50 p-3 text-sm">
              {needsApproval ? (
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 rounded-full bg-yellow-500" />
                  <span className="text-muted-foreground">
                    Step 1: Approve {selectedToken.symbol} spending
                  </span>
                </div>
              ) : (
                <div className="flex items-center gap-2">
                  <div className="h-2 w-2 rounded-full bg-green-500" />
                  <span className="text-muted-foreground">
                    {selectedToken.symbol} approved — ready to commit
                  </span>
                </div>
              )}
            </div>
          )}

          {/* Buttons */}
          <div className="space-y-2">
            {/* Approve Button - always show when approval needed */}
            {needsApproval && (
              <Button
                type="button"
                variant="outline"
                className="w-full"
                onClick={handleApprove}
                disabled={!isConnected || isApproving || !parsedAmount}
              >
                {isApproving
                  ? "Sending..."
                  : `Approve ${selectedToken.symbol}`}
              </Button>
            )}

            {/* Commit Button */}
            <Button
              type="submit"
              className="w-full"
              disabled={
                !isConnected ||
                isCommitPending ||
                !amount ||
                needsApproval
              }
            >
              {!isConnected
                ? "Connect Wallet"
                : isCommitPending
                  ? "Confirming..."
                  : needsApproval
                    ? "Approve First"
                    : `Commit ${isGhostOrder ? "Ghost" : "Yield"} Order`}
            </Button>
          </div>

          {isCommitSuccess ? (
            <p className="text-center text-sm text-green-500">
              Order committed — tokens deposited into MetaMorpho vault.
            </p>
          ) : null}
        </form>
      </CardContent>
    </Card>
  )
}
