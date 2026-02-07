"use client"

import { useState } from "react"
import {
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  useAccount,
} from "wagmi"
import { parseUnits, formatUnits } from "viem"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { ORACLE_ADDRESS } from "@/lib/contracts"

// MockChainlinkOracle ABI (minimal)
const oracleAbi = [
  {
    name: "price",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "int256" }],
  },
  {
    name: "setPrice",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "_price", type: "int256" }],
    outputs: [],
  },
  {
    name: "latestRoundData",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { type: "uint80" },
      { type: "int256" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "uint80" },
    ],
  },
] as const

const PRICE_PRESETS = [
  { label: "$2,000", value: "2000" },
  { label: "$2,500", value: "2500" },
  { label: "$3,000", value: "3000" },
  { label: "$3,500", value: "3500" },
]

export function OracleControls() {
  const { isConnected } = useAccount()
  const [customPrice, setCustomPrice] = useState("")

  // Read current price
  const { data: currentPrice, refetch: refetchPrice } = useReadContract({
    address: ORACLE_ADDRESS,
    abi: oracleAbi,
    functionName: "price",
    query: { refetchInterval: 5000 },
  })

  // Set price tx
  const {
    writeContract,
    data: hash,
    isPending,
    reset,
  } = useWriteContract()

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  })

  const handleSetPrice = (priceUsd: string) => {
    const priceWith8Decimals = parseUnits(priceUsd, 8)
    writeContract({
      address: ORACLE_ADDRESS,
      abi: oracleAbi,
      functionName: "setPrice",
      args: [priceWith8Decimals],
    })
  }

  const handleCustomPrice = () => {
    if (!customPrice) return
    handleSetPrice(customPrice)
  }

  // Format price for display
  const formattedPrice = currentPrice
    ? `$${Number(formatUnits(currentPrice as bigint, 8)).toLocaleString()}`
    : "—"

  // Refetch after success
  if (isSuccess) {
    refetchPrice()
    reset()
  }

  const isOracleConfigured = ORACLE_ADDRESS !== "0x0000000000000000000000000000000000000000"

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Oracle Price</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {!isOracleConfigured ? (
          <p className="text-sm text-muted-foreground">
            Set NEXT_PUBLIC_ORACLE_ADDRESS in .env.local
          </p>
        ) : (
          <>
            {/* Current Price */}
            <div className="rounded-lg bg-muted p-3 text-center">
              <p className="text-xs text-muted-foreground">ETH/USD</p>
              <p className="text-2xl font-bold">{formattedPrice}</p>
            </div>

            {/* Preset Buttons */}
            <div className="grid grid-cols-4 gap-2">
              {PRICE_PRESETS.map(preset => (
                <Button
                  key={preset.value}
                  variant="outline"
                  size="sm"
                  onClick={() => handleSetPrice(preset.value)}
                  disabled={!isConnected || isPending || isConfirming}
                >
                  {preset.label}
                </Button>
              ))}
            </div>

            {/* Custom Price */}
            <div className="flex gap-2">
              <Input
                type="number"
                placeholder="Custom price"
                value={customPrice}
                onChange={e => setCustomPrice(e.target.value)}
                className="flex-1"
              />
              <Button
                variant="secondary"
                onClick={handleCustomPrice}
                disabled={!isConnected || isPending || isConfirming || !customPrice}
              >
                {isPending || isConfirming ? "..." : "Set"}
              </Button>
            </div>

            {!isConnected && (
              <p className="text-xs text-center text-muted-foreground">
                Connect wallet to set price
              </p>
            )}
          </>
        )}
      </CardContent>
    </Card>
  )
}
