"use client"

import { CastCommands } from "@/components/cast-commands"
import { OrderList } from "@/components/order-list"

export function Dashboard() {
  return (
    <div className="mx-auto max-w-2xl px-6 py-8">
      {/* Hero */}
      <div className="mb-8 space-y-2 text-center">
        <h2 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          GhostVault Protocol Demo
        </h2>
        <p className="text-muted-foreground">
          Run cast commands in terminal, view orders below. Funds earn yield in
          MetaMorpho while waiting for execution.
        </p>
      </div>

      {/* Protocol Stats */}
      <div className="mb-8 grid grid-cols-3 gap-4">
        <div className="rounded-lg border border-border bg-card p-4 text-center">
          <p className="text-xs text-muted-foreground">Protocol</p>
          <p className="text-lg font-semibold text-foreground">Uniswap v4</p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4 text-center">
          <p className="text-xs text-muted-foreground">Yield Source</p>
          <p className="text-lg font-semibold text-foreground">MetaMorpho</p>
        </div>
        <div className="rounded-lg border border-border bg-card p-4 text-center">
          <p className="text-xs text-muted-foreground">Oracle</p>
          <p className="text-lg font-semibold text-foreground">Chainlink</p>
        </div>
      </div>

      {/* Cast Commands (Input) */}
      <div className="mb-8">
        <CastCommands />
      </div>

      {/* Orders (Output) */}
      <div>
        <h3 className="mb-4 text-lg font-semibold text-foreground">
          Orders (Read from Chain)
        </h3>
        <OrderList />
      </div>

      {/* Footer */}
      <div className="mt-12 text-center text-xs text-muted-foreground">
        <p>GhostVault Protocol — ETH Global Hack Money 2026</p>
        <p className="mt-1">
          Uniswap v4 Hooks &middot; MetaMorpho Vaults &middot; Chainlink Oracles
        </p>
      </div>
    </div>
  )
}
