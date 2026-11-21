# FACET Smart Contracts (`@facet/contracts`)

[![FACET](https://img.shields.io/badge/FACET-facet.briandev.space-050505?style=flat-square&labelColor=DFFF4F)](https://facet.briandev.space)
[![Layer](https://img.shields.io/badge/AVALANCHE-SMART%20CONTRACTS-0D0D0D?style=flat-square&labelColor=343434)](https://github.com/facet-aex)

> Foundry Solidity smart-contract suite powering FACET's capability registry, x402 payment split, escrow, and on-chain receipts on Avalanche.

## Overview

`contracts` contains the on-chain protocol layer for **FACET**, built with Foundry and OpenZeppelin. These contracts anchor capability integrity, execute programmable `fUSD` revenue splits and escrow refunds, and persist verifiable execution receipts on Avalanche.

## Role in FACET

- **`FacetUSD.sol` (`fUSD`):** Six-decimal ERC-20 testnet stablecoin with EIP-3009 `transferWithAuthorization` and `receiveWithAuthorization` support for gasless x402 client authorizations.
- **`FacetActorRegistry.sol`:** On-chain capability registry anchoring `facetId`, `facetType` (`API` / `ACTOR` / `AGENT`), `imageDigest`, `schemaURI`, pricing metadata, `payTo`, and `erc8004TokenId`.
- **`FacetFeeSplitAndEscrow.sol` (v2):** Settles instant `PAY_PER_RUN` revenue splits (`FeeSplit`) and holds/settles `PAY_PER_RESULT` deposits (`TaskEscrow`) using recipient-bound `receiveWithAuthorization`, EIP-712 domain-separated `EscrowUsageProof` settlement, bounded `expiresAt` deadlines (`15 minutes` default), permissionless post-expiry `refundEscrow`, and `Ownable2Step` surplus recovery (`rescueSurplus`). Deploy script: `scripts/deploy-fee-split-v2-fuji.mjs`.
- **`FacetUsageProof.sol` & `FacetReceiptLog.sol`:** Verify EIP-191 runner signatures over usage commitments and record immutable `RunReceiptLogged` proofs on-chain.

## Tech Stack

| Layer | Technology |
|---|---|
| Smart Contracts | Solidity `0.8.28`, OpenZeppelin Contracts 5 |
| Toolchain & Testing | Foundry (`forge`) |
| Deployment Scripts | Node.js 24, `viem` |
| Network | Avalanche C-Chain (Fuji `eip155:43113`) |

---

Part of **[FACET](https://facet.briandev.space)** (`facet-aex`) — Federated Agent Capability Exchange & Trust on Avalanche.
