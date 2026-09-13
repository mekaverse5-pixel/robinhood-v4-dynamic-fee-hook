# Robinhood V4 Dynamic Fee Rebalance Hook

`DynamicFeeRebalanceHook` is a non-upgradeable, non-custodial Uniswap v4 hook for volatility-aware LP fees on Robinhood Chain.

## Mainnet deployment

- Network: Robinhood Chain Mainnet (`4663`)
- Hook: `0xC538C832BF24e2bC53EB19dECEFa0BCFD59Dd0C4`
- Deployment transaction: `0xac76c2c187b93e1c0ee2b11336faa1f031a74bef1b19b96fc620bef0d083fda1`
- PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`

Source and ABI are published in this repository:

- Solidity source: [`src/DynamicFeeRebalanceHook.sol`](./src/DynamicFeeRebalanceHook.sol)
- ABI JSON: [`abi/DynamicFeeRebalanceHook.abi.json`](./abi/DynamicFeeRebalanceHook.abi.json)

## Functionality

- Per-pool EMA of tick movement drives the dynamic LP fee.
- Immutable fee bounds: 5 bp minimum and 10% protocol-wide ceiling.
- Fee movement is capped at 20 bp per observed block.
- Optional reference-price protection applies only to initialization and explicit rebalance suggestions.
- Revenue claims are held through PoolManager ERC-6909 accounting and paid to the configured recipient.
- No liquidity-removal callbacks and no PositionManager NFT custody.

## Security

The hook enables only `afterInitialize`, `beforeSwap`, `afterSwap`, and `afterSwapReturnDelta`. It does not enable `beforeSwapReturnDelta` or any liquidity-removal callback. Configuration changes use a 24-hour delay and a 7-day execution window. See [`SECURITY_REVIEW.md`](./SECURITY_REVIEW.md).

The review is a first-party project review, not an independent audit or an endorsement by Uniswap Labs. The Foundry suite passes 32/32 tests.

## Build and test

Install dependencies in a local checkout:

```bash
forge install foundry-rs/forge-std --no-commit
forge install Uniswap/v4-core --no-commit
forge install Uniswap/v4-periphery --no-commit
forge install OpenZeppelin/uniswap-hooks --no-commit
```

Then run:

```bash
forge fmt --check
forge test --fuzz-runs 10000
```

Never commit private keys, RPC credentials, keystore passwords, or API keys.
