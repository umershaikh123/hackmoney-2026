"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { useRevealDataStore } from "@/stores/reveal-data-store"

function exportForAgent(): string {
  const state = useRevealDataStore.getState()
  const agentFormat: Record<
    string,
    { targetPrice: string; zeroForOne: boolean; salt: string }
  > = {}

  for (const [orderId, intentHash] of Object.entries(state.orderIntentHashes)) {
    const reveal = state.reveals[intentHash]
    if (reveal) {
      agentFormat[orderId] = {
        targetPrice: reveal.targetPrice,
        zeroForOne: reveal.zeroForOne,
        salt: reveal.salt,
      }
    }
  }

  return JSON.stringify(agentFormat, null, 2)
}

export function ExportRevealData() {
  const [copied, setCopied] = useState(false)
  const [jsonData, setJsonData] = useState("")

  const orderIntentHashes = useRevealDataStore(state => state.orderIntentHashes)
  const clear = useRevealDataStore(state => state.clear)
  const orderCount = Object.keys(orderIntentHashes).length

  const handleOpen = (open: boolean) => {
    if (open) {
      setJsonData(exportForAgent())
      setCopied(false)
    }
  }

  const handleCopy = async () => {
    await navigator.clipboard.writeText(jsonData)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base">Agent Export</CardTitle>
        <CardDescription>
          Export reveal data for the solver agent
        </CardDescription>
      </CardHeader>
      <CardContent>
        <div className="flex gap-2">
          <Dialog onOpenChange={handleOpen}>
            <DialogTrigger asChild>
              <Button variant="outline" className="flex-1">
                Export ({orderCount})
              </Button>
            </DialogTrigger>
          <DialogContent className="max-w-3xl">
            <DialogHeader>
              <DialogTitle>Reveal Data for Agent</DialogTitle>
              <DialogDescription>
                Copy this JSON to <code>agent/reveal-data.json</code> so the
                solver agent can execute your orders.
              </DialogDescription>
            </DialogHeader>

            <div className="relative">
              <pre className="max-h-80 overflow-auto rounded-lg border border-border bg-muted p-4 text-xs whitespace-pre-wrap break-all">
                {jsonData || "{}"}
              </pre>
            </div>

            <DialogFooter>
              <Button
                onClick={handleCopy}
                variant={copied ? "secondary" : "default"}
              >
                {copied ? "Copied!" : "Copy to Clipboard"}
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
          <Button
            variant="destructive"
            onClick={clear}
            disabled={orderCount === 0}
          >
            Clear
          </Button>
        </div>

        <p className="mt-2 text-xs text-muted-foreground">
          The agent needs reveal data (targetPrice, zeroForOne, salt) to execute
          orders on your behalf.
        </p>
      </CardContent>
    </Card>
  )
}
