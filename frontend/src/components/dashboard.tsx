"use client"

import { CreateOrderCard } from "@/components/create-order-card"
import { OracleControls } from "@/components/oracle-controls"
import { TimeWarpControls } from "@/components/time-warp-controls"
import { ExportRevealData } from "@/components/export-reveal-data"
import { OrderList } from "@/components/order-list"

export function Dashboard() {
  return (
    <div className="mx-auto max-w-4xl px-6 py-8">
      {/* Hero */}
      <div className="mb-8 space-y-2 text-center">
        <h2 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          GhostVault Protocol
        </h2>
        <p className="text-muted-foreground">
          Privacy-preserving limit orders with yield. Funds earn in MetaMorpho
          while waiting.
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

      {/* Main Grid: Create Order + Controls */}
      <div className="mb-8 grid gap-6 lg:grid-cols-2">
        {/* Left: Create Order */}
        <CreateOrderCard />

        {/* Right: Oracle + Time Controls + Agent Export */}
        <div className="space-y-6">
          <OracleControls />
          <TimeWarpControls />
          <ExportRevealData />
        </div>
      </div>

      {/* Orders List */}
      <div>
        <h3 className="mb-4 text-lg font-semibold text-foreground">
          Your Orders
        </h3>
        <OrderList />
      </div>

      {/* Footer */}
      <div className="mt-12 text-center text-xs text-muted-foreground">
        <p>GhostVault Protocol — ETH Global Hack Money 2026</p>
        <p className="mt-1">
          Uniswap v4 Hooks · MetaMorpho Vaults · Chainlink Oracles
        </p>
      </div>
    </div>
  )
}
