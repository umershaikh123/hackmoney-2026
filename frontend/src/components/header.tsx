"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Separator } from "@/components/ui/separator";

export function Header() {
  return (
    <header className="border-b border-border bg-card">
      <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="flex size-9 items-center justify-center rounded-lg bg-primary text-primary-foreground font-bold text-sm">
            GV
          </div>
          <div>
            <h1 className="text-lg font-semibold tracking-tight text-foreground">
              GhostVault
            </h1>
            <p className="text-xs text-muted-foreground">
              Privacy-preserving limit orders with yield
            </p>
          </div>
        </div>
        <div className="flex items-center gap-4">
          <div className="hidden items-center gap-2 text-xs text-muted-foreground sm:flex">
            <span className="inline-block size-2 rounded-full bg-green-500" />
            Base (Anvil Fork)
          </div>
          <Separator orientation="vertical" className="hidden h-6 sm:block" />
          <ConnectButton
            showBalance={true}
            chainStatus="icon"
            accountStatus="address"
          />
        </div>
      </div>
    </header>
  );
}
