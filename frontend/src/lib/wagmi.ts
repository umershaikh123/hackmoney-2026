import { http, createConfig } from "wagmi";
import { base } from "wagmi/chains";
import { getDefaultConfig } from "@rainbow-me/rainbowkit";

// Anvil fork of Base mainnet — all mainnet state available locally
const ANVIL_RPC = "http://127.0.0.1:8545";

export const config = getDefaultConfig({
  appName: "GhostVault Protocol",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "demo",
  chains: [base],
  transports: {
    [base.id]: http(ANVIL_RPC),
  },
  ssr: true,
});
