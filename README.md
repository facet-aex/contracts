# FACET USD (fUSD)

Testnet-only FACET payment token for the supervised Fuji demo. It is **not USD Coin, not redeemable for USD and has no backing claim**.

Network: Avalanche Fuji C-Chain (`43113`). Name: `FACET USD`. Symbol: `fUSD`. Decimals: `6`. EIP-712 name/version: `FACET USD` / `2`. The contract implements ERC-20 and EIP-3009 `transferWithAuthorization` for x402 exact payments. The owner can mint; deployment assigns ownership directly to `0x9Ba67CbB2af751af5e874a7EB57691828F43658e` and initially mints 1,000 fUSD to that owner and 100 fUSD to the local demo payer. There is no upgrade proxy, pause, blacklist or fiat redemption.

Deployed contract: `0xe7082a54a456dc4dfe0ceadcd0d0dce7d8ba176f`; deployment transaction and verified metadata are in [fuji-deployment.json](fuji-deployment.json). Import the address on the Fuji network in a wallet to display it. Only the owner's wallet can call `mint(address,uint256)`; `1 fUSD` is `1,000,000` atomic units. `transferOwnership(address)` moves that right. The local deployment key is not owner.

`@openzeppelin/contracts` 5.6.1 (MIT, maintained upstream) provides ERC-20, Ownable, EIP-712 and ECDSA; viem 2.57.17 (MIT, maintained upstream) deploys and checks Fuji state. Foundry 1.9.0 compiles and tests the contract. Dependencies and licenses were checked on 2026-11-11. This is an independent repository with its own `package-lock.json`.

```sh
npm ci
forge test
forge build
```

The deploy script must verify Fuji chain ID, owner, bytecode, metadata, domain and initial balances before reporting an address. Never commit a deployer key.
