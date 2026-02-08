"use client"

import { create } from "zustand"

export type LogType = "info" | "success" | "error" | "tx" | "oracle" | "time"

export interface LogEntry {
  timestamp: string
  type: LogType
  message: string
  txHash?: string
}

interface LogStore {
  logs: LogEntry[]
  addLog: (type: LogType, message: string, txHash?: string) => void
  clear: () => void
}

export const useLogStore = create<LogStore>((set) => ({
  logs: [],

  addLog: (type, message, txHash) => {
    const timestamp = new Date().toLocaleTimeString("en-US", {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    })

    set((state) => ({
      logs: [
        ...state.logs,
        { timestamp, type, message, txHash },
      ].slice(-100), // Keep last 100 logs
    }))
  },

  clear: () => set({ logs: [] }),
}))

// Helper function to format tx hash for display
export function formatTxHash(hash: string): string {
  return `${hash.slice(0, 10)}...${hash.slice(-8)}`
}
