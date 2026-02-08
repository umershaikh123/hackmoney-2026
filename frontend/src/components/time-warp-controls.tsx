"use client"

import { useState } from "react"
import { usePublicClient, useBlock } from "wagmi"
import { useQueryClient } from "@tanstack/react-query"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { useLogStore } from "@/stores/log-store"

const TIME_PRESETS = [
  { label: "1 Hour", seconds: 3600 },
  { label: "1 Day", seconds: 86400 },
  { label: "1 Week", seconds: 604800 },
  { label: "30 Days", seconds: 2592000 },
]

export function TimeWarpControls() {
  const publicClient = usePublicClient()
  const queryClient = useQueryClient()
  const { data: block, refetch: refetchBlock } = useBlock({ watch: true })
  const [isWarping, setIsWarping] = useState(false)
  const [lastWarp, setLastWarp] = useState<string | null>(null)
  const addLog = useLogStore(state => state.addLog)

  const handleWarp = async (seconds: number, label: string) => {
    if (!publicClient) return

    setIsWarping(true)
    setLastWarp(null)
    addLog("time", `Warping time forward +${label}...`)

    try {
      // Call evm_increaseTime (Anvil-specific RPC)
      await publicClient.request({
        method: "evm_increaseTime",
        params: [seconds],
      } as any)

      // Mine a block to apply the time change
      await publicClient.request({
        method: "evm_mine",
        params: [],
      } as any)

      setLastWarp(`+${label}`)
      refetchBlock()

      // Invalidate all contract read queries to refresh order values
      queryClient.invalidateQueries({ queryKey: ["readContract"] })

      addLog("time", `Time warped +${label}. Yield accruing...`)
    } catch (error) {
      console.error("Time warp failed:", error)
      setLastWarp("Failed")
      addLog("error", `Time warp failed: ${error}`)
    } finally {
      setIsWarping(false)
    }
  }

  // Format block timestamp
  const blockTime = block?.timestamp
    ? new Date(Number(block.timestamp) * 1000).toLocaleString()
    : "—"

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Time Warp</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {/* Current Block Time */}
        <div className="rounded-lg bg-muted p-3 text-center">
          <p className="text-xs text-muted-foreground">Block Time</p>
          <p className="text-sm font-mono">{blockTime}</p>
          {lastWarp && (
            <p className="text-xs text-green-500 mt-1">{lastWarp}</p>
          )}
        </div>

        {/* Warp Buttons */}
        <div className="grid grid-cols-2 gap-2">
          {TIME_PRESETS.map(preset => (
            <Button
              key={preset.label}
              variant="outline"
              size="sm"
              onClick={() => handleWarp(preset.seconds, preset.label)}
              disabled={isWarping}
            >
              {isWarping ? "..." : `+${preset.label}`}
            </Button>
          ))}
        </div>

        <p className="text-xs text-center text-muted-foreground">
          Advances Anvil block.timestamp. Yield accrues with time.
        </p>
      </CardContent>
    </Card>
  )
}
