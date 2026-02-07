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

  // Store reveal data by intentHash
  setReveal: (intentHash: string, data: RevealData) => void

  // Get reveal data by intentHash
  getReveal: (intentHash: string) => RevealData | null

  // Clear all
  clear: () => void
}

export const useRevealDataStore = create<RevealDataStore>()(
  persist(
    (set, get) => ({
      reveals: {},

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

      getReveal: (intentHash) => {
        const stored = get().reveals[intentHash]
        if (!stored) return null
        return {
          targetPrice: BigInt(stored.targetPrice),
          zeroForOne: stored.zeroForOne,
          salt: stored.salt as `0x${string}`,
        }
      },

      clear: () => set({ reveals: {} }),
    }),
    {
      name: "reveal-data-storage",
    }
  )
)
