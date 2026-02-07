"use client"

import { useState } from "react"
import {
  useAccount,
  useWriteContract,
  useWaitForTransactionReceipt,
} from "wagmi"
import { useQueryClient } from "@tanstack/react-query"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import { Skeleton } from "@/components/ui/skeleton"
import { OrderCard } from "@/components/order-card"
import { useUserOrders } from "@/hooks/use-ghost-vault"
import { useOrderEvents } from "@/hooks/use-order-events"
import { useRevealDataStore } from "@/stores/reveal-data-store"
import { ghostVaultAbi } from "@/lib/abi"
import { GHOST_VAULT_ADDRESS } from "@/lib/contracts"

export function OrderList() {
  const { isConnected } = useAccount()
  const { orderIds, isLoading } = useUserOrders()
  const queryClient = useQueryClient()

  // Batch selection state
  const [selectedOrders, setSelectedOrders] = useState<Set<bigint>>(new Set())
  const [batchMode, setBatchMode] = useState(false)

  // Batch execute tx
  const {
    writeContract: writeBatchExecute,
    data: batchHash,
    isPending: batchPending,
    error: batchWriteError,
    reset: resetBatch,
  } = useWriteContract()

  const {
    isLoading: batchConfirming,
    isSuccess: batchSuccess,
    error: batchReceiptError,
    data: batchReceipt,
  } = useWaitForTransactionReceipt({
    hash: batchHash,
    query: {
      refetchOnWindowFocus: false,
    },
  })

  const batchReverted = batchReceipt?.status === "reverted"

  const batchError = batchHash
    ? batchWriteError ||
      batchReceiptError ||
      (batchReverted ? new Error("Batch execution reverted") : null)
    : batchWriteError

  if (batchSuccess && batchHash) {
    queryClient.invalidateQueries({ queryKey: ["readContract"] })
  }

  // Fetch and cache order events (executed/cancelled results)
  useOrderEvents()

  const toggleSelection = (orderId: bigint) => {
    setSelectedOrders(prev => {
      const next = new Set(prev)
      if (next.has(orderId)) {
        next.delete(orderId)
      } else {
        next.add(orderId)
      }
      return next
    })
  }

  const [batchValidationError, setBatchValidationError] = useState<
    string | null
  >(null)

  const handleBatchExecute = () => {
    if (selectedOrders.size < 2) return
    setBatchValidationError(null)

    const orderIdArray = Array.from(selectedOrders)
    const reveals: {
      targetPrice: bigint
      zeroForOne: boolean
      salt: `0x${string}`
    }[] = []

    const getRevealByOrderId = useRevealDataStore.getState().getRevealByOrderId
    let firstDirection: boolean | null = null

    for (const orderId of orderIdArray) {
      const revealData = getRevealByOrderId(orderId.toString())
      if (!revealData) {
        setBatchValidationError(`No reveal data for order #${orderId}`)
        return
      }

      // Validate all orders have the same direction
      if (firstDirection === null) {
        firstDirection = revealData.zeroForOne
      } else if (revealData.zeroForOne !== firstDirection) {
        setBatchValidationError(
          "All orders must have the same swap direction (zeroForOne)",
        )
        return
      }

      reveals.push({
        targetPrice: revealData.targetPrice,
        zeroForOne: revealData.zeroForOne,
        salt: revealData.salt,
      })
    }

    writeBatchExecute({
      address: GHOST_VAULT_ADDRESS,
      abi: ghostVaultAbi,
      functionName: "executeBatch",
      args: [orderIdArray, reveals],
    })
  }

  const clearSelection = () => {
    setSelectedOrders(new Set())
    setBatchMode(false)
    setBatchValidationError(null)
    resetBatch()
  }

  if (!isConnected) {
    return (
      <Card>
        <CardContent className="flex min-h-48 items-center justify-center p-6">
          <p className="text-muted-foreground">
            Connect your wallet to view orders
          </p>
        </CardContent>
      </Card>
    )
  }

  if (isLoading) {
    return (
      <div className="space-y-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Card key={i}>
            <CardContent className="space-y-3 p-4">
              <Skeleton className="h-4 w-24" />
              <Skeleton className="h-4 w-full" />
              <Skeleton className="h-4 w-16" />
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  if (orderIds.length === 0) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>My Orders</CardTitle>
          <CardDescription>No orders found</CardDescription>
        </CardHeader>
        <CardContent className="flex min-h-32 items-center justify-center">
          <p className="text-sm text-muted-foreground">
            Commit your first order to get started. Your tokens earn yield while
            waiting.
          </p>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className="space-y-3">
      {/* Batch Mode Controls */}
      <div className="flex items-center justify-between">
        <Button
          variant={batchMode ? "secondary" : "outline"}
          size="sm"
          onClick={() => {
            setBatchMode(!batchMode)
            if (batchMode) clearSelection()
          }}
        >
          {batchMode ? "Exit Batch Mode" : "Batch Execute"}
        </Button>

        {batchMode && selectedOrders.size > 0 && (
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">
              {selectedOrders.size} selected
            </span>
            <Button
              size="sm"
              onClick={handleBatchExecute}
              disabled={
                selectedOrders.size < 2 ||
                batchPending ||
                (batchConfirming && !batchError)
              }
            >
              {batchPending
                ? "Signing..."
                : batchConfirming && !batchError
                  ? "Confirming..."
                  : `Execute ${selectedOrders.size} Orders`}
            </Button>
          </div>
        )}
      </div>

      {/* Batch Mode Info */}
      {batchMode && (
        <div className="rounded-lg border border-primary/20 bg-primary/5 p-3 text-sm">
          <p className="font-medium text-primary">Privacy Batch Execution</p>
          <p className="text-muted-foreground text-xs mt-1">
            Select 2+ orders to execute them in a single aggregated swap.
            On-chain observers will see one large swap instead of individual
            orders.
          </p>
        </div>
      )}

      {/* Batch Validation Error */}
      {batchValidationError && (
        <div className="rounded-lg bg-yellow-500/10 border border-yellow-500/20 p-3 text-sm text-yellow-400">
          {batchValidationError}
        </div>
      )}

      {/* Batch Transaction Error */}
      {batchError && (
        <div className="rounded-lg bg-red-500/10 border border-red-500/20 p-3 text-sm text-red-400">
          Batch execution failed:{" "}
          {batchError.message?.slice(0, 100) || "Transaction reverted"}
        </div>
      )}

      {/* Batch Success */}
      {batchSuccess && (
        <div className="rounded-lg bg-green-500/10 border border-green-500/20 p-3 text-sm text-green-400">
          Batch execution successful! {selectedOrders.size} orders executed
          together.
          <Button
            variant="ghost"
            size="sm"
            className="ml-2"
            onClick={clearSelection}
          >
            Clear
          </Button>
        </div>
      )}

      {/* Render orders (newest first) */}
      {[...orderIds].reverse().map(id => (
        <OrderCard
          key={id.toString()}
          orderId={id}
          batchMode={batchMode}
          isSelected={selectedOrders.has(id)}
          onToggleSelect={() => toggleSelection(id)}
        />
      ))}
    </div>
  )
}
