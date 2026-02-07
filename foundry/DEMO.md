# GhostVault Demo

## Setup

```bash
# Terminal 1: Anvil fork
make demo-anvil

# Terminal 2: Deploy everything
make demo-mock
```

Hook: `0x3EB83B5592Fa61C8Db81945294A854D37badc0C0`

---

## Environment

```bash
HOOK=0x3EB83B5592Fa61C8Db81945294A854D37badc0C0
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC=http://127.0.0.1:8545
```

---

## Ghost Order: Execute

```bash
# Reveal data
SALT=0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
INTENT_HASH=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" 0 false $SALT))

# Approve + Commit (1000 USDC, 60s delay)
cast send $USDC "approve(address,uint256)" $HOOK 1000000000 --private-key $PK --rpc-url $RPC
cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 1000000000 $INTENT_HASH 1 60 0 "($WETH,$USDC,3000,60,$HOOK)" --private-key $PK --rpc-url $RPC

# Warp time
cast rpc evm_increaseTime 120 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

# Execute
cast send $HOOK "executeOrder(uint256,(uint256,bool,bytes32))" 0 "(0,false,$SALT)" --private-key $PK --rpc-url $RPC
```

---

## Ghost Order: Cancel

```bash
# Reveal data
SALT2=0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd
INTENT_HASH2=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" 0 false $SALT2))

# Approve + Commit (2000 USDC)
cast send $USDC "approve(address,uint256)" $HOOK 2000000000 --private-key $PK --rpc-url $RPC
cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 2000000000 $INTENT_HASH2 1 60 0 "($WETH,$USDC,3000,60,$HOOK)" --private-key $PK --rpc-url $RPC

# Warp 7 days for yield
cast rpc evm_increaseTime 604800 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

# Check value
cast call $HOOK "getOrderValue(uint256)(uint256,uint256)" 1 --rpc-url $RPC

# Cancel (returns principal + yield)
cast send $HOOK "cancelOrder(uint256)" 1 --private-key $PK --rpc-url $RPC
```

---

## Yield Order: Price-Triggered

```bash
# Target $3000 (8 decimals)
SALT3=0x9999999999999999999999999999999999999999999999999999999999999999
TARGET=300000000000
INTENT_HASH3=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" $TARGET false $SALT3))

# Approve + Commit (5000 USDC, type=0)
cast send $USDC "approve(address,uint256)" $HOOK 5000000000 --private-key $PK --rpc-url $RPC
cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 5000000000 $INTENT_HASH3 0 0 0 "($WETH,$USDC,3000,60,$HOOK)" --private-key $PK --rpc-url $RPC

# Execute when price >= $3000
cast send $HOOK "executeOrder(uint256,(uint256,bool,bytes32))" 2 "($TARGET,false,$SALT3)" --private-key $PK --rpc-url $RPC
```

---

## Query Commands

```bash
# Order count
cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC

# Order details
cast call $HOOK "getOrder(uint256)" 0 --rpc-url $RPC

# Order value (currentValue, yieldAccrued)
cast call $HOOK "getOrderValue(uint256)(uint256,uint256)" 0 --rpc-url $RPC

# Balances
cast call $USDC "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url $RPC
cast call $WETH "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url $RPC
```

---

## Order Types

| Type | Value | Trigger |
|------|-------|---------|
| YieldOrder | 0 | Price reaches target |
| GhostOrder | 1 | Time delay passes |

## Commit-Reveal

```
intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt))
```

- Ghost: `targetPrice = 0`
- Yield: `targetPrice = price * 10^8` (e.g., $3000 = 300000000000)
- `zeroForOne = false` (sell USDC for WETH)
- `salt` = random 32 bytes
