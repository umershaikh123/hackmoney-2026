import { create } from 'zustand'
import { persist } from 'zustand/middleware'

export interface SwapData {
  amount0: bigint  // WETH delta (negative = received)
  amount1: bigint  // USDC delta (positive = paid)
  sqrtPriceX96: bigint
  tick: number
}

export interface OrderExecutedResult {
  orderId: bigint
  owner: string
  solver: string
  amountOut: bigint
  yieldEarned: bigint
  solverFee: bigint
  swap?: SwapData  // Uniswap swap details
  txHash?: string
}

export interface OrderCancelledResult {
  orderId: bigint
  owner: string
  principalReturned: bigint
  yieldEarned: bigint
}

export type OrderResult =
  | { type: 'executed'; data: OrderExecutedResult }
  | { type: 'cancelled'; data: OrderCancelledResult }

interface OrderResultsState {
  // Map of orderId -> result data
  results: Record<string, OrderResult>
  // Last block we fetched events from
  lastFetchedBlock: bigint

  // Actions
  setExecutedResult: (result: OrderExecutedResult) => void
  setCancelledResult: (result: OrderCancelledResult) => void
  setLastFetchedBlock: (block: bigint) => void
  getResult: (orderId: bigint) => OrderResult | undefined
}

export const useOrderResultsStore = create<OrderResultsState>()(
  persist(
    (set, get) => ({
      results: {},
      lastFetchedBlock: 0n,

      setExecutedResult: (result) => set((state) => ({
        results: {
          ...state.results,
          [result.orderId.toString()]: { type: 'executed', data: result }
        }
      })),

      setCancelledResult: (result) => set((state) => ({
        results: {
          ...state.results,
          [result.orderId.toString()]: { type: 'cancelled', data: result }
        }
      })),

      setLastFetchedBlock: (block) => set({ lastFetchedBlock: block }),

      getResult: (orderId) => get().results[orderId.toString()],
    }),
    {
      name: 'order-results-storage',
      // Custom serialization for bigint values
      storage: {
        getItem: (name) => {
          const str = localStorage.getItem(name)
          if (!str) return null
          const parsed = JSON.parse(str)
          // Convert string bigints back to bigint
          if (parsed.state?.results) {
            for (const key in parsed.state.results) {
              const result = parsed.state.results[key]
              if (result.type === 'executed') {
                result.data.orderId = BigInt(result.data.orderId)
                result.data.amountOut = BigInt(result.data.amountOut)
                result.data.yieldEarned = BigInt(result.data.yieldEarned)
                result.data.solverFee = BigInt(result.data.solverFee)
                if (result.data.swap) {
                  result.data.swap.amount0 = BigInt(result.data.swap.amount0)
                  result.data.swap.amount1 = BigInt(result.data.swap.amount1)
                  result.data.swap.sqrtPriceX96 = BigInt(result.data.swap.sqrtPriceX96)
                }
              } else if (result.type === 'cancelled') {
                result.data.orderId = BigInt(result.data.orderId)
                result.data.principalReturned = BigInt(result.data.principalReturned)
                result.data.yieldEarned = BigInt(result.data.yieldEarned)
              }
            }
          }
          if (parsed.state?.lastFetchedBlock) {
            parsed.state.lastFetchedBlock = BigInt(parsed.state.lastFetchedBlock)
          }
          return parsed
        },
        setItem: (name, value) => {
          // Convert bigints to strings for JSON serialization
          const toSerialize = JSON.parse(JSON.stringify(value, (_, v) =>
            typeof v === 'bigint' ? v.toString() : v
          ))
          localStorage.setItem(name, JSON.stringify(toSerialize))
        },
        removeItem: (name) => localStorage.removeItem(name),
      },
    }
  )
)
