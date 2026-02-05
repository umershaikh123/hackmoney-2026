"use client";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { CommitOrderForm } from "@/components/commit-order-form";
import { OrderList } from "@/components/order-list";

export function Dashboard() {
  return (
    <div className="mx-auto max-w-2xl px-6 py-8">
      {/* Hero */}
      <div className="mb-8 space-y-2 text-center">
        <h2 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          Privacy-Preserving Limit Orders
        </h2>
        <p className="text-muted-foreground">
          Deposit into MetaMorpho vaults, earn yield while you wait, and execute
          via Uniswap v4 hooks when your target price hits.
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

      {/* Tabs */}
      <Tabs defaultValue="commit" className="w-full">
        <TabsList className="grid w-full grid-cols-2">
          <TabsTrigger value="commit">Commit Order</TabsTrigger>
          <TabsTrigger value="orders">My Orders</TabsTrigger>
        </TabsList>
        <TabsContent value="commit" className="mt-4">
          <CommitOrderForm />
        </TabsContent>
        <TabsContent value="orders" className="mt-4">
          <OrderList />
        </TabsContent>
      </Tabs>

      {/* Footer */}
      <div className="mt-12 text-center text-xs text-muted-foreground">
        <p>
          GhostVault Protocol — ETH Global Hack Money 2026
        </p>
        <p className="mt-1">
          Uniswap v4 Hooks &middot; MetaMorpho Vaults &middot; Chainlink Oracles
        </p>
      </div>
    </div>
  );
}
