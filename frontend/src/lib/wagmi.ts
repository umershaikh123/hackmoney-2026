import { http, createConfig } from "wagmi"
import { defineChain } from "viem"
import { getDefaultConfig } from "@rainbow-me/rainbowkit"

import { connectorsForWallets } from "@rainbow-me/rainbowkit"
import {
  rainbowWallet,
  walletConnectWallet,
  injectedWallet,
  safeWallet,
  rabbyWallet,
  metaMaskWallet,
} from "@rainbow-me/rainbowkit/wallets"
// Custom Anvil chain — forked from Base mainnet but with unique chain ID
const anvilBaseFork = defineChain({
  id: 31337,
  name: "Anvil Base Fork",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: ["http://127.0.0.1:8545"],
    },
  },
  testnet: true,
})

const Connectors = connectorsForWallets(
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

  connectors: Connectors,
  ssr: true,

  transports: {
    [anvilBaseFork.id]: http("http://127.0.0.1:8545"),
  },
})
