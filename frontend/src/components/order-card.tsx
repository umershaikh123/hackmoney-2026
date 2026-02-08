"use client"

import { useEffect } from "react"
import { formatUnits } from "viem"
import {
  useAccount,
  useBlock,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi"
import { useQueryClient } from "@tanstack/react-query"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useGetOrder, useGetOrderValue } from "@/hooks/use-ghost-vault"
import { useOrderResult } from "@/hooks/use-order-events"
import { useRevealDataStore } from "@/stores/reveal-data-store"
import { ghostVaultAbi } from "@/lib/abi"
import {
  ORDER_TYPE_LABELS,
  ORDER_STATUS_LABELS,
  OrderStatus,
  OrderType,
  USDC,
  WETH,
  GHOST_VAULT_ADDRESS,
} from "@/lib/contracts"
import { useLogStore } from "@/stores/log-store"

function tokenSymbol(address: string): string {
  const lower = address.toLowerCase()
  if (lower === USDC.toLowerCase()) return "USDC"
  if (lower === WETH.toLowerCase()) return "WETH"
  return `${address.slice(0, 6)}...`
}

function tokenDecimals(address: string): number {
  return address.toLowerCase() === USDC.toLowerCase() ? 6 : 18
}

// Format elapsed time in human-readable format
function formatElapsedTime(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86400) {
    const hours = Math.floor(seconds / 3600)
    const mins = Math.floor((seconds % 3600) / 60)
    return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`
  }
  if (seconds < 604800) {
    const days = Math.floor(seconds / 86400)
    const hours = Math.floor((seconds % 86400) / 3600)
    return hours > 0 ? `${days}d ${hours}h` : `${days}d`
  }
  const weeks = Math.floor(seconds / 604800)
  const days = Math.floor((seconds % 604800) / 86400)
  return days > 0 ? `${weeks}w ${days}d` : `${weeks}w`
}

const STATUS_VARIANT: Record<number, "default" | "secondary" | "outline"> = {
  [OrderStatus.ACTIVE]: "default",
  [OrderStatus.EXECUTED]: "secondary",
  [OrderStatus.CANCELLED]: "outline",
}

interface OrderCardProps {
  orderId: bigint
  batchMode?: boolean
  isSelected?: boolean
  onToggleSelect?: () => void
}

export function OrderCard({
  orderId,
  batchMode = false,
  isSelected = false,
  onToggleSelect,
}: OrderCardProps) {
  const { address } = useAccount()
  const queryClient = useQueryClient()
  const getReveal = useRevealDataStore(state => state.getReveal)
  const removeOrder = useRevealDataStore(state => state.removeOrder)
  const addLog = useLogStore(state => state.addLog)

  const { data: order, isLoading: orderLoading } = useGetOrder(orderId)

  const { data: value, isLoading: valueLoading } = useGetOrderValue(orderId)

  const orderResult = useOrderResult(orderId)

  const { data: block } = useBlock({ watch: true })

  // Cancel order tx
  const {
    writeContract: writeCancel,
    data: cancelHash,
    isPending: cancelPending,
    error: cancelWriteError,
    reset: resetCancel,
  } = useWriteContract()

  const {
    isLoading: cancelConfirming,
    isSuccess: cancelSuccess,
    isError: cancelReceiptFailed,
    error: cancelReceiptError,
    data: cancelReceipt,
  } = useWaitForTransactionReceipt({ hash: cancelHash })

  // Execute order tx
  const {
    writeContract: writeExecute,
    data: executeHash,
    isPending: executePending,
    error: executeWriteError,
    reset: resetExecute,
  } = useWriteContract()

  const {
    isLoading: executeConfirming,
    isSuccess: executeSuccess,
    isError: executeReceiptFailed,
    error: executeReceiptError,
    data: executeReceipt,
  } = useWaitForTransactionReceipt({ hash: executeHash })

  // Check for reverted transactions (status === 'reverted')
  const cancelReverted = cancelReceipt?.status === "reverted"
  const executeReverted = executeReceipt?.status === "reverted"

  const cancelError =
    cancelWriteError ||
    cancelReceiptError ||
    (cancelReverted ? new Error("Transaction reverted") : null)
  const executeError =
    executeWriteError ||
    executeReceiptError ||
    (executeReverted ? new Error("Transaction reverted") : null)

  // Cleanup reveal data and refresh queries after successful cancel
  useEffect(() => {
    if (cancelSuccess && !cancelReverted) {
      removeOrder(orderId.toString())
      queryClient.invalidateQueries({ queryKey: ["readContract"] })
    }
  }, [cancelSuccess, cancelReverted, orderId, removeOrder, queryClient])

  // Cleanup reveal data and refresh queries after successful execute
  useEffect(() => {
    if (executeSuccess && !executeReverted) {
      removeOrder(orderId.toString())
      queryClient.invalidateQueries({ queryKey: ["readContract"] })
    }
  }, [executeSuccess, executeReverted, orderId, removeOrder, queryClient])

  // Log transaction submissions
  useEffect(() => {
    if (cancelHash) {
      addLog("tx", `Cancel tx submitted:`, cancelHash)
    }
  }, [cancelHash, addLog])

  useEffect(() => {
    if (executeHash) {
      addLog("tx", `Execute tx submitted:`, executeHash)
    }
  }, [executeHash, addLog])

  // Log confirmations
  useEffect(() => {
    if (cancelSuccess && !cancelReverted && cancelHash) {
      addLog("success", `Order #${orderId} cancelled! Funds returned.`, cancelHash)
    }
  }, [cancelSuccess, cancelReverted, cancelHash, orderId, addLog])

  useEffect(() => {
    if (executeSuccess && !executeReverted && executeHash) {
      addLog("success", `Order #${orderId} executed! Swap complete.`, executeHash)
    }
  }, [executeSuccess, executeReverted, executeHash, orderId, addLog])

  const getErrorMessage = (error: Error | null): string | null => {
    if (!error) return null
    const msg = error.message || ""

    const revertMatch = msg.match(
      /reverted with the following reason:\s*(.+?)(?:\n|$)/i,
    )
    if (revertMatch) return revertMatch[1].trim()

    const customErrorMatch = msg.match(/error (\w+)\(\)/i)
    if (customErrorMatch) return customErrorMatch[1]

    if (msg.includes("PriceConditionNotMet")) return "Price condition not met"
    if (msg.includes("OracleStale")) return "Oracle price is stale"
    if (msg.includes("DelayNotElapsed")) return "Delay not elapsed"
    if (msg.includes("NotOrderOwner")) return "Not order owner"
    if (msg.includes("OrderNotActive")) return "Order not active"
    // Generic fallback
    if (msg.length > 100) return "Transaction reverted"
    return msg
  }

  if (orderLoading) {
    return (
      <Card>
        <CardContent className="space-y-3 p-4">
          <Skeleton className="h-4 w-24" />
          <Skeleton className="h-4 w-full" />
          <Skeleton className="h-4 w-16" />
        </CardContent>
      </Card>
    )
  }

  if (!order) return null

  const data = order as readonly [
    string,
    number,
    number,
    string,
    bigint,
    bigint,
    string,
    bigint,
    bigint,
  ]
  const owner = data[0]
  const orderTypeNum = Number(data[1])
  const statusNum = Number(data[2])
  const tokenIn = data[3]
  const amountIn = data[4]
  const intentHash = data[6] as `0x${string}`
  const createdAt = data[7]
  const minDelay = data[8]

  // Filter: only show orders belonging to the connected wallet
  if (address && owner.toLowerCase() !== address.toLowerCase()) {
    return null
  }

  const symbol = tokenSymbol(tokenIn)
  const decimals = tokenDecimals(tokenIn)
  const formattedAmount = formatUnits(amountIn, decimals)
  const isActive = statusNum === OrderStatus.ACTIVE
  const isGhostOrder = orderTypeNum === OrderType.GHOST_ORDER

  // Get reveal data from store
  const revealData = getReveal(intentHash)
  const canExecute = isActive && revealData !== null

  // Check if ghost order delay has passed
  const delayPassed = isGhostOrder
    ? (block?.timestamp
        ? Number(block.timestamp)
        : Math.floor(Date.now() / 1000)) >=
      Number(createdAt) + Number(minDelay)
    : true

  const handleCancel = () => {
    addLog("info", `Cancelling Order #${orderId}...`)
    writeCancel({
      address: GHOST_VAULT_ADDRESS,
      abi: ghostVaultAbi,
      functionName: "cancelOrder",
      args: [orderId],
    })
  }

  const handleExecute = () => {
    if (!revealData) return
    addLog("info", `Executing Order #${orderId}...`)
    addLog("info", `Revealing: price=${revealData.targetPrice}, zeroForOne=${revealData.zeroForOne}`)
    writeExecute({
      address: GHOST_VAULT_ADDRESS,
      abi: ghostVaultAbi,
      functionName: "executeOrder",
      args: [
        orderId,
        {
          targetPrice: revealData.targetPrice,
          zeroForOne: revealData.zeroForOne,
          salt: revealData.salt,
        },
      ],
    })
  }

  // getOrderValue returns: [currentValue, yieldAccrued]
  const valueData = value as readonly [bigint, bigint] | undefined
  const currentValue = valueData ? formatUnits(valueData[0], decimals) : "—"
  const yieldAccrued = valueData ? formatUnits(valueData[1], decimals) : "0"

  const createdDate = new Date(Number(createdAt) * 1000)
  const formattedDate = createdAt > 0n ? createdDate.toLocaleDateString() : "—"

  // Calculate elapsed time using block timestamp (reflects Anvil time warps)
  const blockTimestamp = block?.timestamp
    ? Number(block.timestamp)
    : Math.floor(Date.now() / 1000)
  const elapsedSeconds = createdAt > 0n ? blockTimestamp - Number(createdAt) : 0
  const timeActive =
    elapsedSeconds > 0 ? formatElapsedTime(elapsedSeconds) : "—"

  const canSelect = batchMode && isActive && revealData !== null

  return (
    <Card
      className={`${isActive ? "" : "opacity-50"} ${isSelected ? "ring-2 ring-primary" : ""}`}
    >
      <CardHeader className="flex flex-row items-center justify-between space-y-0 p-4 pb-2">
        <div className="flex items-center gap-3">
          {/* Batch Selection Checkbox */}
          {batchMode && (
            <input
              type="checkbox"
              checked={isSelected}
              onChange={onToggleSelect}
              disabled={!canSelect}
              className="h-4 w-4 rounded border-gray-300 text-primary focus:ring-primary disabled:opacity-50"
            />
          )}
          <CardTitle className="text-sm font-medium">
            Order #{orderId.toString()}
          </CardTitle>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant="outline">
            {ORDER_TYPE_LABELS[orderTypeNum] ?? "Unknown"}
          </Badge>
          <Badge variant={STATUS_VARIANT[statusNum] ?? "outline"}>
            {ORDER_STATUS_LABELS[statusNum] ?? "Unknown"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="space-y-2 p-4 pt-0">
        <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
          <span className="text-muted-foreground">Token</span>
          <span className="text-right font-medium">{symbol}</span>

          <span className="text-muted-foreground">Deposited</span>
          <span className="text-right font-mono">
            {formattedAmount} {symbol}
          </span>

          {/* Only show current value and yield for ACTIVE orders */}
          {isActive && (
            <>
              <span className="text-muted-foreground">Current Value</span>
              <span className="text-right font-mono">
                {valueLoading ? (
                  <Skeleton className="ml-auto h-4 w-16" />
                ) : (
                  `${currentValue} ${symbol}`
                )}
              </span>

              <span className="text-muted-foreground">Yield Earned</span>
              <span className="text-right font-mono text-green-500">
                +{yieldAccrued} {symbol}
              </span>
            </>
          )}

          <span className="text-muted-foreground">Created</span>
          <span className="text-right">{formattedDate}</span>

          {/* Show time active for all orders */}
          <span className="text-muted-foreground">Time Active</span>
          <span className="text-right font-mono text-amber-500">
            {timeActive}
          </span>

          {minDelay > 0n ? (
            <>
              <span className="text-muted-foreground">Min Delay</span>
              <span className="text-right">
                {Number(minDelay / 60n)}m
                {isGhostOrder && (
                  <span
                    className={
                      delayPassed ? " text-green-500" : " text-yellow-500"
                    }
                  >
                    {delayPassed ? " (ready)" : " (waiting)"}
                  </span>
                )}
              </span>
            </>
          ) : null}
        </div>

        {/* Action Buttons for ACTIVE orders */}
        {isActive && (
          <div className="space-y-2 pt-2">
            <div className="flex gap-2">
              <Button
                variant="outline"
                size="sm"
                className="flex-1"
                onClick={() => {
                  resetCancel()
                  handleCancel()
                }}
                disabled={cancelPending || (cancelConfirming && !cancelError)}
              >
                {cancelPending
                  ? "Signing..."
                  : cancelConfirming && !cancelError
                    ? "Confirming..."
                    : "Cancel"}
              </Button>
              <Button
                size="sm"
                className="flex-1"
                onClick={() => {
                  resetExecute()
                  handleExecute()
                }}
                disabled={
                  !canExecute ||
                  executePending ||
                  (executeConfirming && !executeError) ||
                  (isGhostOrder && !delayPassed)
                }
              >
                {executePending
                  ? "Signing..."
                  : executeConfirming && !executeError
                    ? "Confirming..."
                    : !revealData
                      ? "No Reveal Data"
                      : isGhostOrder && !delayPassed
                        ? "Delay Not Passed"
                        : "Execute"}
              </Button>
            </div>

            {/* Error Messages - only show if we attempted this order */}
            {cancelError && cancelHash && (
              <div className="rounded-lg bg-red-500/10 border border-red-500/20 p-2 text-sm text-red-400">
                Cancel failed: {getErrorMessage(cancelError)}
              </div>
            )}
            {cancelWriteError && !cancelHash && (
              <div className="rounded-lg bg-red-500/10 border border-red-500/20 p-2 text-sm text-red-400">
                Cancel failed: {getErrorMessage(cancelWriteError)}
              </div>
            )}
            {executeError && executeHash && (
              <div className="rounded-lg bg-red-500/10 border border-red-500/20 p-2 text-sm text-red-400">
                Execute failed: {getErrorMessage(executeError)}
              </div>
            )}
            {executeWriteError && !executeHash && (
              <div className="rounded-lg bg-red-500/10 border border-red-500/20 p-2 text-sm text-red-400">
                Execute failed: {getErrorMessage(executeWriteError)}
              </div>
            )}
          </div>
        )}

        {/* Executed Order Result */}
        {statusNum === OrderStatus.EXECUTED && (
          <div className="mt-4 rounded-lg bg-green-500/10 p-3">
            <div className="text-sm font-medium text-green-400">
              Order Executed
            </div>
            <div className="space-y-1 mt-2 text-sm">
              {orderResult?.type === "executed" ? (
                <>
                  {/* Show swap details only for single execution (amountOut > 0)
                      For batch execution, amountOut is 0 and swap data is the total, not per-order */}
                  {orderResult.data.swap && orderResult.data.amountOut > 0n ? (
                    <>
                      <div className="flex justify-between">
                        <span className="text-muted-foreground">Swapped</span>
                        <span className="font-mono">
                          {Number(
                            formatUnits(
                              orderResult.data.swap.amount1 > 0n
                                ? orderResult.data.swap.amount1
                                : -orderResult.data.swap.amount1,
                              6,
                            ),
                          ).toFixed(2)}{" "}
                          USDC
                        </span>
                      </div>
                      <div className="flex justify-between">
                        <span className="text-muted-foreground">Received</span>
                        <span className="font-mono">
                          {Number(
                            formatUnits(
                              orderResult.data.swap.amount0 < 0n
                                ? -orderResult.data.swap.amount0
                                : orderResult.data.swap.amount0,
                              18,
                            ),
                          ).toFixed(6)}{" "}
                          WETH
                        </span>
                      </div>
                    </>
                  ) : orderResult.data.amountOut > 0n ? (
                    <div className="flex justify-between">
                      <span className="text-muted-foreground">Received</span>
                      <span className="font-mono">
                        {Number(
                          formatUnits(
                            orderResult.data.amountOut,
                            symbol === "USDC" ? 18 : 6,
                          ),
                        ).toFixed(6)}{" "}
                        {symbol === "USDC" ? "WETH" : "USDC"}
                      </span>
                    </div>
                  ) : (
                    <div className="flex justify-between">
                      <span className="text-muted-foreground">Execution</span>
                      <span className="font-mono text-primary">Batch</span>
                    </div>
                  )}
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Yield Earned</span>
                    <span className="text-green-400 font-mono">
                      +
                      {Number(
                        formatUnits(orderResult.data.yieldEarned, decimals),
                      ).toFixed(2)}{" "}
                      {symbol}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Solver Fee</span>
                    <span className="text-muted-foreground font-mono">
                      -
                      {Number(
                        formatUnits(orderResult.data.solverFee, decimals),
                      ).toFixed(2)}{" "}
                      {symbol}
                    </span>
                  </div>
                </>
              ) : (
                <div className="flex justify-between">
                  <span className="text-muted-foreground">
                    Principal + Yield
                  </span>
                  <span>
                    {formattedAmount}+ {symbol}
                  </span>
                </div>
              )}
              <div className="text-xs text-muted-foreground mt-2">
                Swapped to {symbol === "USDC" ? "WETH" : "USDC"} via Uniswap v4
              </div>
            </div>
          </div>
        )}

        {/* Cancelled Order Result */}
        {statusNum === OrderStatus.CANCELLED && (
          <div className="mt-4 rounded-lg bg-blue-500/10 p-3">
            <div className="text-sm font-medium text-blue-400">
              Funds Returned
            </div>
            <div className="space-y-1 mt-2 text-sm">
              {orderResult?.type === "cancelled" ? (
                <>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Principal</span>
                    <span className="font-mono">
                      {formattedAmount} {symbol}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Yield Earned</span>
                    <span className="text-green-400 font-mono">
                      +
                      {Number(
                        formatUnits(orderResult.data.yieldEarned, decimals),
                      ).toFixed(2)}{" "}
                      {symbol}
                    </span>
                  </div>
                  <div className="flex justify-between font-medium pt-1 border-t border-border mt-1">
                    <span>Total Returned</span>
                    <span className="font-mono">
                      {Number(
                        formatUnits(
                          orderResult.data.principalReturned,
                          decimals,
                        ),
                      ).toFixed(2)}{" "}
                      {symbol}
                    </span>
                  </div>
                </>
              ) : (
                <div className="flex justify-between">
                  <span className="text-muted-foreground">
                    Principal + Yield
                  </span>
                  <span>
                    {formattedAmount}+ {symbol}
                  </span>
                </div>
              )}
              <div className="text-xs text-muted-foreground mt-2">
                Principal and accrued yield were returned to your wallet
              </div>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
