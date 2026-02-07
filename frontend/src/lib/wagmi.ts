import { http, createConfig } from "wagmi"
import { defineChain } from "viem"

import { connectorsForWallets } from "@rainbow-me/rainbowkit"
import {
  rainbowWallet,
  injectedWallet,
  safeWallet,
  rabbyWallet,
  metaMaskWallet,
} from "@rainbow-me/rainbowkit/wallets"

const anvilBaseFork = defineChain({
  id: 31337,
  name: "Anvil (Base Fork)",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_ANVIL_RPC ?? "http://127.0.0.1:8545"],
    },
  },
  testnet: true,
})

const connectors = connectorsForWallets(
  [
    {
      groupName: "Recommended",
      wallets: [
        metaMaskWallet,
        rainbowWallet,
        injectedWallet,
        safeWallet,
        rabbyWallet,
      ],
    },
  ],
  {
    appName: "GhostVault Protocol",
    projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "demo",
  },
)

export const config = createConfig({
  chains: [anvilBaseFork],
  connectors,
  ssr: true,
  transports: {
    [anvilBaseFork.id]: http(
      process.env.NEXT_PUBLIC_ANVIL_RPC ?? "http://127.0.0.1:8545",
    ),
  },
})
