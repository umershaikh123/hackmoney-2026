"use client"

import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit"
import { WagmiProvider } from "wagmi"
import { config } from "@/lib/wagmi"
import { useState, type ReactNode } from "react"
import { ReactQueryDevtools } from "@tanstack/react-query-devtools"

import "@rainbow-me/rainbowkit/styles.css"

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient())

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={darkTheme({
            accentColor: "#7c3aed",
            borderRadius: "medium",
          })}
        >
          {children}
          <ReactQueryDevtools initialIsOpen={false} client={queryClient} />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
