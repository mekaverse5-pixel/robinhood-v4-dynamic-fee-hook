# DynamicFeeRebalanceHook security review

Review date: 2026-09-12

Scope: `src/DynamicFeeRebalanceHook.sol`, its Uniswap v4 interactions, deployment
script, configuration lifecycle, fee accounting, oracle guard, and local tests.
This is a first-party review using the `v4-security-foundations` checklist. It is
not an independent audit or an endorsement by Uniswap Labs.

## Release design

- The hook address enables only `afterInitialize`, `beforeSwap`, `afterSwap`, and
  `afterSwapReturnDelta`.
- Liquidity removal has no hook callback, so the hook cannot block LP exits.
- Production pool creation uses `initializePool` or `initializePoolWithOracle`.
  Configuration and PoolManager initialization complete atomically in one
  transaction. The legacy two-transaction staging path remains only for the
  already-deployed testnet client.
- Direct PoolManager initialization without a valid pending configuration reverts.
- Pool owners and fee recipients are explicit per pool. Ownership transfer is
  two-step, and mutable configuration changes are delayed and cancellable.

## Fee and balance safety

- The immutable hook ceiling is 100,000 pips (10%). Each pool may choose a lower
  immutable maximum.
- Dynamic fee movement is limited to 2,000 pips (20 bp) per observed block, and
  only one volatility observation is recorded per block.
- Hook revenue is capped at 10% of the estimated LP fee. Exact-input fees are
  charged in output currency; exact-output fees are charged in input currency.
- Positive `afterSwapReturnDelta` values are backed by PoolManager ERC-6909 claims
  minted to the hook. Claims zero accounting before unlock and accept callbacks
  only from PoolManager.
- Pool IDs isolate configuration, fee state, oracle state, and claimable balances.

## Oracle and liveness

- The optional oracle checks only pool initialization and explicit rebalance
  suggestions. It never runs on swaps or liquidity removal.
- Oracle contracts must exist, report a nonzero price and timestamp, be within the
  configured age/deviation bounds, and report the market open.
- A stale, closed, reverting, or divergent oracle cannot freeze trading or exits.
- Without an oracle, initial price remains initializer-supplied and should be
  treated as untrusted until liquidity and price impact are reviewed.

## Verification evidence

- Foundry formatting and compilation pass with Solidity 0.8.30.
- Runtime bytecode is 23,412 bytes, 1,164 bytes below the EIP-170 limit.
- The deployment script rejects creation bytecode other than the reviewed 24,300
  bytes and rejects a deployed runtime other than the reviewed 23,412 bytes.
- 32/32 tests pass, including atomic initialization, hostile pending-config
  replacement, rollback on oracle failure, exact-input/output revenue, partial
  fills, same-block observation isolation, fee ceilings, delayed configuration,
  ownership transfer, pool isolation, and unrestricted liquidity removal.
- A forced clean rebuild resolves deterministic Robinhood mainnet CREATE2 address
  `0xC538C832BF24e2bC53EB19dECEFa0BCFD59Dd0C4` with salt `0x8989` and the canonical
  PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- A forced Robinhood mainnet simulation at a capped gas price of 0.205 gwei uses
  one transaction, estimates 6,781,799 gas, and requires at most
  0.001390268795 ETH before broadcast.

The earlier address `0x52aF4a4B45Cd3d04e40219f5e08a8D75CECa10C4`
contains a stale pre-fix build artifact. It has no configured pools or assets and
is permanently excluded from every client and deployment manifest.

## Robinhood mainnet deployment

- Hook: `0xC538C832BF24e2bC53EB19dECEFa0BCFD59Dd0C4`
- Transaction: `0xac76c2c187b93e1c0ee2b11336faa1f031a74bef1b19b96fc620bef0d083fda1`
- Block: `61706899`
- Actual deployment cost: `0.000450668518742 ETH`
- On-chain runtime: 23,412 bytes
- PoolManager binding: `0x8366a39CC670B4001A1121B8F6A443A643e40951`
- Permission bits: `afterInitialize`, `beforeSwap`, `afterSwap`, and
  `afterSwapReturnDelta` only
- On-chain ceilings: 100,000 pips maximum LP fee, 2,000 pips maximum fee
  movement per observed block, and 1,000 bps maximum Hook revenue cut

## Robinhood mainnet smoke-test pool

- Pair: WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` / USDG
  `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- Pool ID: `0x5124e1d8e3f90a40c93d2f030bd43065d407d9bda8783e3e0fed6bb9e5c4b628`
- Atomic pool initialization transaction:
  `0xf008fe241012712d56b3cbc44523ae1da57b563f427b0159c53eae13809d1c0f`
- Position mint transaction:
  `0x692a7a2c57ba0190f9c1b61595d2f80e50b4029801dc7bded2b3272f256d114e`
- Position NFT: `2594307`; liquidity: `231954455535`; range:
  `-198600` to `-197400`; initial tick: `-197990`
- Pool bounds are 500-10,000 pips (5-100 bp), base fee 3,000 pips,
  volatility coefficient 25, maximum step 2,000 pips, and Hook revenue cut
  500 bps (5% of the estimated LP fee).
- WETH to USDG transaction:
  `0xf7fa3c8310cafc1789d63761b5c1603deeb12e0c887af888e250a0ea91c6684d`.
  Exact input was 5,000,000,000,000 wei WETH; user output was 12,560
  micro-USDG; effective fee was 3,000 pips; Hook revenue was 1 micro-USDG.
- USDG to WETH transaction:
  `0x0bf4bae756d5f4440faf8d041a0bde016f8fde0c753f81b649ee31cb680828fb`.
  Exact input was 10,000 micro-USDG; user output was 3,956,510,226,766 wei
  WETH; effective fee rose to 3,050 pips exactly as
  `baseFee + emaTickMovement * volatilityCoeff`; Hook revenue was
  605,306,303 wei WETH.
- Both swap receipts have status 1. The post-swap state is tick `-197995`, EMA
  movement `3`, last effective fee `3050`, and no rebalance signal.
- The official Robinhood Universal Router uses a newer v4-periphery single-hop
  ABI with `minHopPriceX36`; the production smoke-test script pins that exact
  verified layout and simulations must pass before any broadcast.
- Production UI verification found the pool by either one-token search or the
  exact WETH/USDG pair, displayed 30.5 bp and the live USD liquidity estimate,
  detected NFT `2594307`, and reproduced the position value and proportional
  exit previews from current on-chain state.

## Remaining production gates

- [x] Deploy the reviewed bytecode to the deterministic mainnet address.
- [x] Verify runtime bytecode, PoolManager binding, and permission bits on-chain.
- [ ] Publish verified source on the mainnet explorer.
- [x] Create a small mainnet pool and test swaps in both directions.
- [x] Confirm live fee movement, revenue accounting, and UI values against receipts.
- [ ] Arrange an independent audit before materially scaling TVL.

Public RPC availability and token-specific behavior remain operational risks. A
dedicated RPC, event indexing, timelock monitoring, and conservative launch limits
are required before a broad public rollout.
