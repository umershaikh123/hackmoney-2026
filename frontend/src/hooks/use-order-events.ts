"use client"

import { useEffect } from 'react'
import { usePublicClient } from 'wagmi'
import { parseAbiItem } from 'viem'
import { GHOST_VAULT_ADDRESS, POOL_MANAGER } from '@/lib/contracts'
import { useOrderResultsStore, type SwapData } from '@/stores/order-results-store'

// Event signatures from GhostVaultHookV2
const ORDER_EXECUTED_EVENT = parseAbiItem(
  'event OrderExecuted(uint256 indexed orderId, address indexed owner, address indexed solver, uint256 amountOut, uint256 yieldEarned, uint256 solverFee)'
)
const ORDER_CANCELLED_EVENT = parseAbiItem(
  'event OrderCancelled(uint256 indexed orderId, address indexed owner, uint256 principalReturned, uint256 yieldEarned)'
)

// Uniswap v4 PoolManager Swap event
const SWAP_EVENT = parseAbiItem(
  'event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)'
)

export function useOrderEvents() {
  const publicClient = usePublicClient()
  const { setExecutedResult, setCancelledResult, lastFetchedBlock, setLastFetchedBlock } = useOrderResultsStore()

  useEffect(() => {
    if (!publicClient) return

    const fetchEvents = async () => {
      try {
        const currentBlock = await publicClient.getBlockNumber()

        // Fetch from last fetched block or from a reasonable starting point
        const fromBlock = lastFetchedBlock > 0n ? lastFetchedBlock + 1n : 0n

        // Don't fetch if we're already caught up
        if (fromBlock > currentBlock) return

        // Fetch OrderExecuted events
        const executedLogs = await publicClient.getLogs({
          address: GHOST_VAULT_ADDRESS as `0x${string}`,
          event: ORDER_EXECUTED_EVENT,
          fromBlock,
          toBlock: currentBlock,
        })

        // Fetch Swap events from PoolManager where sender is our hook
        const swapLogs = await publicClient.getLogs({
          address: POOL_MANAGER as `0x${string}`,
          event: SWAP_EVENT,
          fromBlock,
          toBlock: currentBlock,
          args: {
            sender: GHOST_VAULT_ADDRESS as `0x${string}`,
          },
        })

        // Create a map of txHash -> swap data for correlation
        const swapsByTxHash = new Map<string, SwapData>()
        for (const log of swapLogs) {
          if (log.transactionHash && log.args.amount0 !== undefined) {
            swapsByTxHash.set(log.transactionHash, {
              amount0: log.args.amount0,
              amount1: log.args.amount1 || 0n,
              sqrtPriceX96: log.args.sqrtPriceX96 || 0n,
              tick: log.args.tick || 0,
            })
          }
        }

        // Process executed orders with swap data
        for (const log of executedLogs) {
          if (log.args.orderId !== undefined) {
            const swap = log.transactionHash ? swapsByTxHash.get(log.transactionHash) : undefined
            setExecutedResult({
              orderId: log.args.orderId,
              owner: log.args.owner || '',
              solver: log.args.solver || '',
              amountOut: log.args.amountOut || 0n,
              yieldEarned: log.args.yieldEarned || 0n,
              solverFee: log.args.solverFee || 0n,
              swap,
              txHash: log.transactionHash,
            })
          }
        }

        // Fetch OrderCancelled events
        const cancelledLogs = await publicClient.getLogs({
          address: GHOST_VAULT_ADDRESS as `0x${string}`,
          event: ORDER_CANCELLED_EVENT,
          fromBlock,
          toBlock: currentBlock,
        })

        for (const log of cancelledLogs) {
          if (log.args.orderId !== undefined) {
            setCancelledResult({
              orderId: log.args.orderId,
              owner: log.args.owner || '',
              principalReturned: log.args.principalReturned || 0n,
              yieldEarned: log.args.yieldEarned || 0n,
            })
          }
        }

        setLastFetchedBlock(currentBlock)
      } catch (error) {
        console.error('Error fetching order events:', error)
      }
    }

    fetchEvents()

    // Poll for new events every 5 seconds
    const interval = setInterval(fetchEvents, 5000)
    return () => clearInterval(interval)
  }, [publicClient, lastFetchedBlock, setExecutedResult, setCancelledResult, setLastFetchedBlock])
}

// Hook to get result for a specific order
export function useOrderResult(orderId: bigint) {
  const getResult = useOrderResultsStore((state) => state.getResult)
  return getResult(orderId)
}
