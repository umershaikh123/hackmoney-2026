// Extracted from foundry build artifact: GhostVaultHookV2.json
import ghostVaultAbiJson from "@/lib/abi/ghostVaultAbi.json"
import { erc20Abi as ERC20_ABI } from "viem"
export const ghostVaultAbi = ghostVaultAbiJson as typeof ghostVaultAbiJson

export const erc20Abi = ERC20_ABI
