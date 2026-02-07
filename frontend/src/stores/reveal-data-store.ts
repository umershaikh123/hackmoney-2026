"use client"

import { create } from "zustand"
import { persist } from "zustand/middleware"

export interface RevealData {
  targetPrice: bigint
  zeroForOne: boolean
  salt: `0x${string}`
}

interface RevealDataStore {
  // Map of order intentHash -> reveal data
  reveals: Record<string, { targetPrice: string; zeroForOne: boolean; salt: string }>

  // Map of orderId -> intentHash (for batch execution lookup)
  orderIntentHashes: Record<string, string>

  // Store reveal data by intentHash
  setReveal: (intentHash: string, data: RevealData) => void

  // Link an orderId to its intentHash (called after order creation)
  linkOrderId: (orderId: string, intentHash: string) => void

  // Get reveal data by intentHash
  getReveal: (intentHash: string) => RevealData | null

  // Get reveal data by orderId
  getRevealByOrderId: (orderId: string) => RevealData | null

  // Get intentHash for an orderId
  getIntentHash: (orderId: string) => string | null

  // Remove reveal data for an executed/cancelled order
  removeOrder: (orderId: string) => void

  // Clear all
  clear: () => void
}

export const useRevealDataStore = create<RevealDataStore>()(
  persist(
    (set, get) => ({
      reveals: {},
      orderIntentHashes: {},

      setReveal: (intentHash, data) => {
        set(state => ({
          reveals: {
            ...state.reveals,
            [intentHash]: {
              targetPrice: data.targetPrice.toString(),
              zeroForOne: data.zeroForOne,
              salt: data.salt,
            },
          },
        }))
      },

      linkOrderId: (orderId, intentHash) => {
        set(state => ({
          orderIntentHashes: {
            ...state.orderIntentHashes,
            [orderId]: intentHash,
          },
        }))
      },

      getReveal: (intentHash) => {
        const stored = get().reveals[intentHash]
        if (!stored) return null
        return {
          targetPrice: BigInt(stored.targetPrice),
          zeroForOne: stored.zeroForOne,
          salt: stored.salt as `0x${string}`,
        }
      },

      getRevealByOrderId: (orderId) => {
        const intentHash = get().orderIntentHashes[orderId]
        if (!intentHash) return null
        return get().getReveal(intentHash)
      },

      getIntentHash: (orderId) => {
        return get().orderIntentHashes[orderId] || null
      },

      removeOrder: (orderId) => {
        const intentHash = get().orderIntentHashes[orderId]
        if (!intentHash) return

        set(state => {
          const { [intentHash]: _, ...remainingReveals } = state.reveals
          const { [orderId]: __, ...remainingHashes } = state.orderIntentHashes
          return {
            reveals: remainingReveals,
            orderIntentHashes: remainingHashes,
          }
        })
      },

      clear: () => set({ reveals: {}, orderIntentHashes: {} }),
    }),
    {
      name: "reveal-data-storage",
    }
  )
)
