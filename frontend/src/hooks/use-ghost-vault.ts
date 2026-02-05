"use client"

import { useReadContract, useWriteContract, useAccount } from "wagmi"
import { ghostVaultAbi } from "@/lib/abi"
import { GHOST_VAULT_ADDRESS, DEFAULT_POOL_KEY } from "@/lib/contracts"
import type { Address } from "viem"

const contractConfig = {
  address: GHOST_VAULT_ADDRESS,
  abi: ghostVaultAbi,
} as const

export function useNextOrderId() {
  return useReadContract({
    ...contractConfig,
    functionName: "nextOrderId",
    query: { refetchInterval: 5_000 },
  })
}

export function useGetOrder(orderId: bigint) {
  return useReadContract({
    ...contractConfig,
    functionName: "getOrder",
    args: [orderId],
  })
}

export function useGetOrderValue(orderId: bigint) {
  return useReadContract({
    ...contractConfig,
    functionName: "getOrderValue",
    args: [orderId],
  })
}

export function useCommitOrder() {
  const { writeContract, ...rest } = useWriteContract()

  function commitOrder(
    tokenIn: Address,
    amountIn: bigint,
    intentHash: `0x${string}`,
    orderType: number,
    minDelay: bigint,
    minAmountOut: bigint,
  ) {
    writeContract({
      ...contractConfig,
      functionName: "commitOrder",
      args: [
        tokenIn,
        amountIn,
        intentHash,
        orderType,
        minDelay,
        minAmountOut,
        DEFAULT_POOL_KEY,
      ],
    })
  }

  return { commitOrder, ...rest }
}

export function useCancelOrder() {
  const { writeContract, ...rest } = useWriteContract()

  function cancelOrder(orderId: bigint) {
    writeContract({
      ...contractConfig,
      functionName: "cancelOrder",
      args: [orderId],
    })
  }

  return { cancelOrder, ...rest }
}

// Returns order ID range for the parent component to iterate
export function useUserOrders() {
  const { address } = useAccount()
  const { data: nextId, isLoading } = useNextOrderId()

  const orderIds: bigint[] = []
  if (nextId) {
    const total = BigInt(nextId as number)
    for (let i = 0n; i < total; i++) {
      orderIds.push(i)
    }
  }

  return { orderIds, isLoading, address }
}
