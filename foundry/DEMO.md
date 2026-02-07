# GhostVault Demo Guide

Complete working demo flow for GhostVault on Anvil Base fork.

---

## Quick Start (Full Demo Setup)

```bash
# Terminal 1: Start Anvil fork
make demo-anvil

# Terminal 2: Full setup (deploy hook, vault, pool)
make demo-full
```

---

## Manual Setup Steps

If you prefer running each step individually:

### Step 1: Start Anvil Fork

```bash
# Terminal 1
make demo-anvil
```

### Step 2: Deploy Hook + Fund Account

```bash
# Terminal 2
make demo-setup
```

### Step 3: Deploy SimpleYieldVault

Replaces MetaMorpho (which has liquidity constraints on fork) with our unlimited-liquidity demo vault.

```bash
forge script script/UseSimpleVault.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Step 4: Initialize Pool + Add Liquidity

```bash
forge script script/InitPool.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

---

## Demo Flows

### Environment Variables

```bash
HOOK=0x3EB83B5592Fa61C8Db81945294A854D37badc0C0
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
WETH=0x4200000000000000000000000000000000000006
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC=http://127.0.0.1:8545
```

---

### Ghost Order: Commit → Execute

Time-delayed swap with commit-reveal pattern.

```bash
# 1. Define reveal data (save these!)
SALT=0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef

# 2. Compute intentHash from reveal data
INTENT_HASH=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" 0 false $SALT))
echo "Intent Hash: $INTENT_HASH"

# 3. Approve USDC
cast send $USDC "approve(address,uint256)" $HOOK 1000000000 \
  --private-key $PK --rpc-url $RPC

# 4. Commit Ghost Order (1000 USDC, 60s delay)
cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 1000000000 $INTENT_HASH 1 60 0 \
  "($WETH,$USDC,3000,60,$HOOK)" \
  --private-key $PK --rpc-url $RPC

# 5. Get order ID
ORDER_ID=$(cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC)
ORDER_ID=$((ORDER_ID - 1))
echo "Order ID: $ORDER_ID"

# 6. Warp time past delay
cast rpc evm_increaseTime 120 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

# 7. Execute order (swap USDC → WETH)
cast send $HOOK "executeOrder(uint256,(uint256,bool,bytes32))" \
  $ORDER_ID "(0,false,$SALT)" \
  --private-key $PK --rpc-url $RPC
```

**Expected result:** Order executed, user receives WETH, solver gets 1% of yield as fee.

---

### Ghost Order: Commit → Cancel

Cancel order and receive principal + yield (no solver fee).

```bash
# 1. Define reveal data
SALT2=0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd
INTENT_HASH2=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" 0 false $SALT2))

# 2. Approve and commit
cast send $USDC "approve(address,uint256)" $HOOK 2000000000 \
  --private-key $PK --rpc-url $RPC

cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 2000000000 $INTENT_HASH2 1 60 0 \
  "($WETH,$USDC,3000,60,$HOOK)" \
  --private-key $PK --rpc-url $RPC

# 3. Get order ID
ORDER_ID2=$(cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC)
ORDER_ID2=$((ORDER_ID2 - 1))
echo "Order ID: $ORDER_ID2"

# 4. Warp time to accrue yield (7 days)
cast rpc evm_increaseTime 604800 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

# 5. Check order value before cancel
cast call $HOOK "getOrderValue(uint256)(uint256,uint256)" $ORDER_ID2 --rpc-url $RPC

# 6. Cancel order (returns principal + yield)
cast send $HOOK "cancelOrder(uint256)" $ORDER_ID2 \
  --private-key $PK --rpc-url $RPC
```

**Expected result:** Order cancelled, user receives USDC principal + accrued yield.

---

### Yield Order: Price-Triggered Limit Order

Execute when ETH price reaches target.

```bash
# 1. Define reveal data with target price ($3000 = 300000000000 in 8 decimals)
SALT3=0x9999999999999999999999999999999999999999999999999999999999999999
TARGET_PRICE=300000000000
INTENT_HASH3=$(cast keccak $(cast abi-encode "f(uint256,bool,bytes32)" $TARGET_PRICE false $SALT3))

# 2. Approve and commit Yield Order (type=0)
cast send $USDC "approve(address,uint256)" $HOOK 5000000000 \
  --private-key $PK --rpc-url $RPC

cast send $HOOK "commitOrder(address,uint256,bytes32,uint8,uint256,uint256,(address,address,uint24,int24,address))" \
  $USDC 5000000000 $INTENT_HASH3 0 0 0 \
  "($WETH,$USDC,3000,60,$HOOK)" \
  --private-key $PK --rpc-url $RPC

# 3. Get order ID
ORDER_ID3=$(cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC)
ORDER_ID3=$((ORDER_ID3 - 1))
echo "Yield Order ID: $ORDER_ID3"

# Note: Execute will fail until ETH price >= $3000 (check Chainlink)
```

---

## Query Commands

```bash
# Total orders created
cast call $HOOK "nextOrderId()(uint256)" --rpc-url $RPC

# Get order details
cast call $HOOK "getOrder(uint256)" 0 --rpc-url $RPC

# Get order value (currentValue, yieldAccrued)
cast call $HOOK "getOrderValue(uint256)(uint256,uint256)" 0 --rpc-url $RPC

# Check USDC balance
cast call $USDC "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url $RPC

# Check WETH balance
cast call $WETH "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url $RPC
```

---

## Order Types

| Type | Value | Description |
|------|-------|-------------|
| YieldOrder | 0 | Price-triggered limit order. Executes when Chainlink price meets target. |
| GhostOrder | 1 | Time-delayed swap. Must wait `minDelay` seconds before execution. |

## Order Status

| Status | Value | Description |
|--------|-------|-------------|
| ACTIVE | 0 | Order is open, funds earning yield in vault |
| EXECUTED | 1 | Order was executed, user received output token |
| CANCELLED | 2 | Order was cancelled, user received principal + yield |

---

## Commit-Reveal Pattern

```
intentHash = keccak256(abi.encode(targetPrice, zeroForOne, salt))
```

| Order Type | targetPrice | zeroForOne | salt |
|------------|-------------|------------|------|
| Ghost Order | 0 | false | random 32 bytes |
| Yield Order | price × 10^8 (e.g., 300000000000 = $3000) | false | random 32 bytes |

**Important:** Save your reveal data! Without it, you cannot execute the order.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `HashMismatch` | Reveal data doesn't match committed intentHash | Use same (targetPrice, zeroForOne, salt) as commit |
| `PoolNotInitialized` | Pool not created | Run `InitPool.s.sol` |
| `InsufficientVaultLiquidity` | MetaMorpho liquidity issue | Run `UseSimpleVault.s.sol` |
| `DelayNotElapsed` | Ghost order delay not passed | Warp time: `cast rpc evm_increaseTime 120` |
| `PriceConditionNotMet` | Yield order price not reached | Check Chainlink price or wait |
| `NotOrderOwner` | Trying to cancel someone else's order | Use correct account |

---

## Demo Video Script (3 minutes)

### Intro (15s)
"GhostVault is a Uniswap v4 hook that earns yield on idle order capital."

### Part 1: Setup (30s)
```bash
make demo-full
```
"Hook deployed, SimpleYieldVault configured, pool initialized with liquidity."

### Part 2: Ghost Order Execute (60s)
Run the commit → execute flow above.
"1000 USDC committed with 60s delay. After delay, swap executes. User receives WETH."

### Part 3: Cancel with Yield (45s)
Run the commit → cancel flow above.
"2000 USDC committed. After 7 days, cancel returns principal PLUS accrued yield."

### Part 4: Summary (30s)
"GhostVault demonstrates yield on idle capital, privacy via commit-reveal, and safety via Chainlink oracle validation."

---

## Key Addresses

| Contract | Address |
|----------|---------|
| Hook | `0x3EB83B5592Fa61C8Db81945294A854D37badc0C0` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| WETH | `0x4200000000000000000000000000000000000006` |
| PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| Demo Account | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
