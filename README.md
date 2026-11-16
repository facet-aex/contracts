# FACET Smart Contracts (`@facet/contracts`)

Foundry Solidity smart-contract suite for FACET on **Avalanche Fuji C-Chain (`43113`)** under [ADR-0015](../docs/architecture/decisions/ADR-0015-actorbazaar-docker-and-a2a-mvp.md).

## Contracts

1. **`src/FacetUSD.sol` (`fUSD`):**
   - Deployed at `0xe7082a54a456dc4dfe0ceadcd0d0dce7d8ba176f` on Avalanche Fuji.
   - ERC-20 (`6` decimals) + EIP-3009 `transferWithAuthorization` for x402 payments.
2. **`src/FacetActorRegistry.sol`:**
   - On-chain registry storing `facetId`, `facetType` (`API` / `ACTOR` / `AGENT`), `imageDigest`, `schemaURI`, `pricingModel`, `priceAtomic`, `payTo`, and `erc8004TokenId`.
3. **`src/FacetFeeSplitAndEscrow.sol`:**
   - Instant creator revenue split (`FeeSplit`) for `PAY_PER_RUN` and runner-signed usage settlement + automatic refund (`TaskEscrow`) for `PAY_PER_RESULT`.
4. **`src/FacetReceiptLog.sol`:**
   - Immutable on-chain run receipt log (`inputHash`, `outputHash`, `itemCount`, `paymentTxHash`, `runnerSignature`).

## Commands

```sh
npm ci
forge test
forge build
npm run deploy:fuji
```

Verified Fuji deployment addresses and transaction hashes are recorded in [fuji-deployment.json](fuji-deployment.json).
