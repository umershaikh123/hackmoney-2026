"use client"

import { useState, useMemo, useCallback } from "react"
import { parseUnits, keccak256, encodeAbiParameters } from "viem"
import { Copy, Check, Terminal, RefreshCw } from "lucide-react"

import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { GHOST_VAULT_ADDRESS, USDC, WETH } from "@/lib/contracts"

type OrderType = "yield" | "ghost"

// Generate a random 32-byte salt
function generateSalt(): `0x${string}` {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  return `0x${Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('')}` as `0x${string}`
}

export function CastCommands() {
  const [orderType, setOrderType] = useState<OrderType>("ghost")
  const [amount, setAmount] = useState("1000")
  const [delay, setDelay] = useState("60")
  const [targetPrice, setTargetPrice] = useState("2500")
  const [cancelOrderId, setCancelOrderId] = useState("0")
  const [salt, setSalt] = useState<`0x${string}`>(() => generateSalt())
  const [copiedCmd, setCopiedCmd] = useState<string | null>(null)

  // Separate state for Execute section (user pastes saved reveal data here)
  const [executeOrderId, setExecuteOrderId] = useState("0")
  const [execTargetPrice, setExecTargetPrice] = useState("0")
  const [execZeroForOne, setExecZeroForOne] = useState("false")
  const [execSalt, setExecSalt] = useState("")

  // Regenerate salt
  const regenerateSalt = useCallback(() => {
    setSalt(generateSalt())
  }, [])

  // Parse amount to raw units (6 decimals for USDC)
  const amountRaw = (() => {
    try {
      return parseUnits(amount || "0", 6).toString()
    } catch {
      return "0"
    }
  })()

  // Compute reveal data and intent hash
  // For Ghost Orders: targetPrice=0 (time-based, not price-based)
  // For Yield Orders: targetPrice from input (8 decimals for Chainlink)
  // zeroForOne=false because we're selling USDC (currency1) for WETH (currency0)
  const revealData = useMemo(() => {
    const price = orderType === "yield"
      ? (() => {
          try {
            return parseUnits(targetPrice || "0", 8) // Chainlink uses 8 decimals
          } catch {
            return 0n
          }
        })()
      : 0n
    return {
      targetPrice: price,
      zeroForOne: false,
      salt,
    }
  }, [orderType, targetPrice, salt])

  // Compute intent hash: keccak256(abi.encode(targetPrice, zeroForOne, salt))
  const intentHash = useMemo(() => {
    return keccak256(encodeAbiParameters(
      [
        { name: 'targetPrice', type: 'uint256' },
        { name: 'zeroForOne', type: 'bool' },
        { name: 'salt', type: 'bytes32' },
      ],
      [revealData.targetPrice, revealData.zeroForOne, revealData.salt]
    ))
  }, [revealData])

  const commands = {
    approve: `cast send ${USDC} "approve(address,uint256)" ${GHOST_VAULT_ADDRESS} ${amountRaw} --private-key $PK --rpc-url $RPC`,

    commit: `cast send ${GHOST_VAULT_ADDRESS} "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" ${USDC} ${amountRaw} ${intentHash} ${orderType === "yield" ? "0" : "1"} ${orderType === "ghost" ? delay : "0"} 0 "(${WETH},${USDC},3000,60,${GHOST_VAULT_ADDRESS})" --private-key $PK --rpc-url $RPC`,

    // Execute uses SEPARATE state - user pastes saved reveal data
    execute: `cast send ${GHOST_VAULT_ADDRESS} "executeOrder(uint256,(uint256,bool,bytes32))" ${executeOrderId} "(${execTargetPrice},${execZeroForOne},${execSalt})" --private-key $PK --rpc-url $RPC`,

    cancel: `cast send ${GHOST_VAULT_ADDRESS} "cancelOrder(uint256)" ${cancelOrderId} --private-key $PK --rpc-url $RPC`,
  }

  // JSON format for agent's reveal-data.json
  const revealDataJson = useMemo(() => {
    return JSON.stringify({
      [executeOrderId]: {
        targetPrice: revealData.targetPrice.toString(),
        zeroForOne: revealData.zeroForOne,
        salt: revealData.salt,
      }
    }, null, 2)
  }, [executeOrderId, revealData])

  const copyToClipboard = async (key: string, text: string) => {
    await navigator.clipboard.writeText(text)
    setCopiedCmd(key)
    setTimeout(() => setCopiedCmd(null), 2000)
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Terminal className="h-5 w-5" />
          Cast Commands
        </CardTitle>
        <CardDescription>
          Configure parameters below, copy commands, run in terminal. Orders
          will appear in the viewer below.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {/* Environment Variables Note */}
        <div className="rounded-lg border border-border bg-muted/50 p-3 text-sm">
          <p className="font-medium text-foreground">Set these first:</p>
          <code className="mt-1 block text-xs text-muted-foreground">
            PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
            <br />
            RPC=http://127.0.0.1:8545
          </code>
        </div>

        {/* Order Type Selector */}
        <div className="space-y-2">
          <Label>Order Type</Label>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => setOrderType("ghost")}
              className={`rounded-lg border p-3 text-left text-sm transition-colors ${
                orderType === "ghost"
                  ? "border-primary bg-primary/10 text-foreground"
                  : "border-border bg-card text-muted-foreground hover:border-muted-foreground"
              }`}
            >
              <div className="font-medium">Ghost Order</div>
              <div className="text-xs text-muted-foreground">
                Time-delayed swap
              </div>
            </button>
            <button
              type="button"
              onClick={() => setOrderType("yield")}
              className={`rounded-lg border p-3 text-left text-sm transition-colors ${
                orderType === "yield"
                  ? "border-primary bg-primary/10 text-foreground"
                  : "border-border bg-card text-muted-foreground hover:border-muted-foreground"
              }`}
            >
              <div className="font-medium">Yield Order</div>
              <div className="text-xs text-muted-foreground">
                Price-triggered limit
              </div>
            </button>
          </div>
        </div>

        {/* Amount Input */}
        <div className="space-y-2">
          <Label htmlFor="amount">Amount (USDC)</Label>
          <Input
            id="amount"
            type="number"
            step="any"
            min="0"
            placeholder="1000"
            value={amount}
            onChange={e => setAmount(e.target.value)}
          />
          <p className="text-xs text-muted-foreground">
            Raw value: {amountRaw} (6 decimals)
          </p>
        </div>

        {/* Ghost Order: Delay */}
        {orderType === "ghost" && (
          <div className="space-y-2">
            <Label htmlFor="delay">Minimum Delay (seconds)</Label>
            <Input
              id="delay"
              type="number"
              step="1"
              min="0"
              placeholder="60"
              value={delay}
              onChange={e => setDelay(e.target.value)}
            />
          </div>
        )}

        {/* Yield Order: Target Price */}
        {orderType === "yield" && (
          <div className="space-y-2">
            <Label htmlFor="targetPrice">Target Price (USD)</Label>
            <Input
              id="targetPrice"
              type="number"
              step="any"
              min="0"
              placeholder="2500"
              value={targetPrice}
              onChange={e => setTargetPrice(e.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              ETH price to trigger execution (Chainlink 8 decimals)
            </p>
          </div>
        )}

        {/* Reveal Data (Important for execution) */}
        <div className="rounded-lg border border-amber-500/50 bg-amber-500/10 p-3 text-sm">
          <div className="flex items-center justify-between">
            <p className="font-medium text-foreground">Reveal Data (save for execution!)</p>
            <Button
              size="sm"
              variant="ghost"
              className="h-7 px-2"
              onClick={regenerateSalt}
            >
              <RefreshCw className="mr-1 h-3 w-3" />
              New Salt
            </Button>
          </div>
          <div className="mt-2 space-y-1 font-mono text-xs text-muted-foreground">
            <p>targetPrice: {revealData.targetPrice.toString()}</p>
            <p>zeroForOne: {revealData.zeroForOne.toString()}</p>
            <p className="break-all">salt: {revealData.salt}</p>
          </div>
          <p className="mt-2 text-xs text-amber-600 dark:text-amber-400">
            Intent Hash: <span className="break-all">{intentHash}</span>
          </p>
        </div>

        {/* Commit Commands */}
        <div className="space-y-4">
          <h4 className="text-sm font-medium text-foreground">Create Order</h4>
          <CommandBlock
            step={1}
            label="Approve USDC"
            command={commands.approve}
            copied={copiedCmd === "approve"}
            onCopy={() => copyToClipboard("approve", commands.approve)}
          />
          <CommandBlock
            step={2}
            label={`Commit ${orderType === "ghost" ? "Ghost" : "Yield"} Order`}
            command={commands.commit}
            copied={copiedCmd === "commit"}
            onCopy={() => copyToClipboard("commit", commands.commit)}
          />
        </div>

        {/* Execute Section */}
        <div className="space-y-4 border-t border-border pt-4">
          <h4 className="text-sm font-medium text-foreground">Execute Order</h4>
          <p className="text-xs text-muted-foreground">
            Paste the reveal data you saved when creating this order.
          </p>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="executeId">Order ID</Label>
              <Input
                id="executeId"
                type="number"
                step="1"
                min="0"
                placeholder="0"
                value={executeOrderId}
                onChange={e => setExecuteOrderId(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="execTargetPrice">targetPrice</Label>
              <Input
                id="execTargetPrice"
                type="text"
                placeholder="0"
                value={execTargetPrice}
                onChange={e => setExecTargetPrice(e.target.value)}
              />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="execZeroForOne">zeroForOne</Label>
              <select
                id="execZeroForOne"
                className="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
                value={execZeroForOne}
                onChange={e => setExecZeroForOne(e.target.value)}
              >
                <option value="false">false</option>
                <option value="true">true</option>
              </select>
            </div>
            <div className="space-y-2 col-span-2 sm:col-span-1">
              <Label htmlFor="execSalt">salt</Label>
              <Input
                id="execSalt"
                type="text"
                placeholder="0x..."
                value={execSalt}
                onChange={e => setExecSalt(e.target.value)}
                className="font-mono text-xs"
              />
            </div>
          </div>
          <CommandBlock
            step={3}
            label="Execute Order"
            command={commands.execute}
            copied={copiedCmd === "execute"}
            onCopy={() => copyToClipboard("execute", commands.execute)}
          />
          <p className="text-xs text-muted-foreground">
            Ghost orders require delay to pass; Yield orders require price condition.
          </p>
        </div>

        {/* Cancel Section */}
        <div className="space-y-4 border-t border-border pt-4">
          <h4 className="text-sm font-medium text-foreground">Cancel Order</h4>
          <div className="space-y-2">
            <Label htmlFor="cancelId">Order ID to Cancel</Label>
            <Input
              id="cancelId"
              type="number"
              step="1"
              min="0"
              placeholder="0"
              value={cancelOrderId}
              onChange={e => setCancelOrderId(e.target.value)}
            />
          </div>
          <CommandBlock
            step={4}
            label="Cancel Order"
            command={commands.cancel}
            copied={copiedCmd === "cancel"}
            onCopy={() => copyToClipboard("cancel", commands.cancel)}
          />
        </div>

        {/* Agent Integration */}
        <div className="space-y-2 border-t border-border pt-4">
          <h4 className="text-sm font-medium text-foreground">Agent Integration</h4>
          <p className="text-xs text-muted-foreground">
            Copy this JSON to <code>agent/reveal-data.json</code> for automated execution:
          </p>
          <div className="flex gap-2">
            <code className="flex-1 overflow-x-auto rounded border border-border bg-muted p-2 text-xs">
              {revealDataJson}
            </code>
            <Button
              size="sm"
              variant="outline"
              className="shrink-0"
              onClick={() => copyToClipboard("json", revealDataJson)}
            >
              {copiedCmd === "json" ? (
                <Check className="h-4 w-4 text-green-500" />
              ) : (
                <Copy className="h-4 w-4" />
              )}
            </Button>
          </div>
        </div>
      </CardContent>
    </Card>
  )
}

function CommandBlock({
  step,
  label,
  command,
  copied,
  onCopy,
}: {
  step: number
  label: string
  command: string
  copied: boolean
  onCopy: () => void
}) {
  return (
    <div className="space-y-1.5">
      <Label className="text-sm">
        {step}. {label}
      </Label>
      <div className="flex gap-2">
        <code className="flex-1 overflow-x-auto rounded border border-border bg-muted p-2 text-xs">
          {command}
        </code>
        <Button
          size="sm"
          variant="outline"
          className="shrink-0"
          onClick={onCopy}
        >
          {copied ? (
            <Check className="h-4 w-4 text-green-500" />
          ) : (
            <Copy className="h-4 w-4" />
          )}
        </Button>
      </div>
    </div>
  )
}
