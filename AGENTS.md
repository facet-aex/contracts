# `contracts` instructions (Avalanche Solidity Smart Contracts)

**Owner in Wave 1:** Codex  
**Active architectural authority:** `../docs/architecture/decisions/ADR-0015-actorbazaar-docker-and-a2a-mvp.md`

## Role

This standalone Foundry + Solidity repository (`@facet/contracts`, renamed from `demo-token`) owns all FACET on-chain smart contracts deployed on **Avalanche Fuji C-Chain (`43113`)** (and optionally a dedicated Receipt L1):

1. **`src/FacetUSD.sol` (`fUSD`):**
   - Already deployed on Fuji at `0xe7082a54a456dc4dfe0ceadcd0d0dce7d8ba176f` (6 decimals, EIP-3009 `transferWithAuthorization`, owner `0x9Ba67CbB2af751af5e874a7EB57691828F43658e`). Do not break or replace the existing `fUSD` deployment unless explicitly requested.
2. **`src/FacetActorRegistry.sol` (ActorBazaar & Multi-Modal Facet Registry):**
   - Registers and updates Facets on-chain:
     - `bytes32 facetId` (deterministic `keccak256(bytes(uuid))` or `bytes32` UUID representation)
     - `uint8 facetType` (`0 = EXTERNAL_HTTP_API`, `1 = HOSTED_ACTOR`, `2 = AUTONOMOUS_AGENT`)
     - `bytes32 imageDigest` (for `HOSTED_ACTOR`: `sha256` commitment of runner image + code bundle)
     - `string schemaURI` (manifest URI or content hash string)
     - `uint8 pricingModel` (`0 = PAY_PER_RUN`, `1 = PAY_PER_RESULT`)
     - `uint256 priceAtomic` (price in `fUSD` atomic units)
     - `address payTo` (creator payout address)
     - `uint256 erc8004TokenId` (tokenId on canonical Fuji ERC-8004 Identity Registry `0x8004A818BFB912233c491871b3d84c89A494BD9e`, `0` if none)
     - `bool active`
   - Emits `FacetRegistered(bytes32 indexed facetId, uint8 facetType, bytes32 imageDigest, uint8 pricingModel, uint256 priceAtomic, address indexed payTo, uint256 erc8004TokenId)` and provides view getters so buyers/agents can verify `imageDigest` and `payTo`.
3. **`src/FacetFeeSplitAndEscrow.sol` (Instant Creator Payout & `TaskEscrow` v2 — `ADR-0020`):**
   - Configured with `FacetUSD` (`0xe7082a54a456dc4dfe0ceadcd0d0dce7d8ba176f`), `platformFeeBps` (e.g., `500` = 5%), `platformTreasury`, `runnerSigner`, `settlementOperator`, and `rescueAdmin` (`Ownable2Step`). Uses `EIP712("FacetFeeSplitAndEscrow", "2")` for domain-separated settlement proofs.
   - **Transfer-Pull Safety (EIP-3009 `receiveWithAuthorization`):**
     Both `settlePayPerRunWithAuthorization` and `depositEscrowWithAuthorization` pull `fUSD` via `FacetUSD.receiveWithAuthorization(payer, address(this), ...)` instead of `transferWithAuthorization`, ensuring only the contract itself (`msg.sender == address(this)`) can redeem the signed EIP-3009 authorization and closing front-running griefing.
   - **Canonical Usage Proofs:**
     - **On-chain Receipt Proof (`FacetReceiptLog`):** EIP-191 signature over `keccak256(abi.encodePacked(runId, facetId, inputHash, outputHash, itemCount))`.
     - **Domain-Separated Escrow Settlement Proof (`EscrowUsageProof` v2):** EIP-712 typed struct `EscrowUsageProof(bytes32 runId,bytes32 facetId,bytes32 inputHash,bytes32 outputHash,uint256 itemCount)` bound to `FacetFeeSplitAndEscrow` v2 domain `(chainId, address(this))`.
   - **`PAY_PER_RUN` (`FeeSplit`):**
     Exposes `settlePayPerRunWithAuthorization(bytes32 runId, bytes32 facetId, address payer, address creatorPayTo, uint256 amount, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata payerSignature)` which pulls `amount` via `receiveWithAuthorization` and immediately transfers `95%` to `creatorPayTo` and `5%` to `platformTreasury`, emitting `FeeSplitSettled(runId, facetId, creatorPayTo, creatorAmount, platformFee)`.
   - **`PAY_PER_RESULT` (`TaskEscrow` with Bounded Timeout & Permissionless Reclaim):**
     - `DEFAULT_ESCROW_TIMEOUT = 15 minutes`, `MIN_ESCROW_TIMEOUT = 5 minutes`, `MAX_ESCROW_TIMEOUT = 1 hours`.
     - `depositEscrowWithAuthorization(..., uint64 timeoutSeconds, bytes calldata payerSignature)` (and compatibility 11-arg overload using `DEFAULT_ESCROW_TIMEOUT`): pulls `maxAmount` via `receiveWithAuthorization`, stores `expiresAt = uint64(block.timestamp + timeout)`, increments `totalEscrowed += maxAmount`, and emits `TaskEscrowOpened`.
     - `settleEscrow(bytes32 runId, bytes32 inputHash, bytes32 outputHash, uint256 itemCount, bytes calldata escrowSignature)`: callable by `settlementOperator` OR `task.creatorPayTo` **strictly before `task.expiresAt`**, decrements `totalEscrowed -= task.maxAmount`, verifies `escrowSignature`, splits `actualAmount = min(itemCount * unitPriceAtomic, maxAmount)` (`95%` / `5%`), and refunds `maxAmount - actualAmount` to `payer`.
     - `refundEscrow(bytes32 runId)`: **before `expiresAt`**, only `settlementOperator` may cancel early; **at or after `block.timestamp >= task.expiresAt`**, **any address (permissionless)** can trigger `refundEscrow(runId)` returning `100%` of `task.maxAmount` strictly to `task.payer` and decrementing `totalEscrowed`.
     - `rescueSurplus(address erc20, address to)` (`onlyOwner`, `Ownable2Step`): sweeps accidental ERC-20 transfers only when `balance > totalEscrowed` (for `fUSD`), never touching active escrow liability.
4. **`src/FacetReceiptLog.sol` (On-Chain Run Receipt Log):**
   - Stores and emits immutable execution receipts:
     - `recordReceipt(bytes32 runId, bytes32 facetId, bytes32 inputHash, bytes32 outputHash, uint256 itemCount, bytes32 paymentTxHash, bytes calldata runnerSignature)`
     - Emits `RunReceiptLogged(bytes32 indexed runId, bytes32 indexed facetId, bytes32 inputHash, bytes32 outputHash, uint256 itemCount, bytes32 paymentTxHash, address runnerSigner)`.

## Deliverables in `fuji-deployment.json`

After running `forge test` and deploying to Fuji, update `fuji-deployment.json` to preserve the existing `fUSD` metadata and add `actorRegistry`, `feeSplitAndEscrow`, and `receiptLog` addresses + deployment transaction hashes so `chain-worker`, `gateway`, and `control-api` can read them cleanly.

## Security rules

- Never commit `.env` or any private key.
- Validate all contract invariants with Foundry tests (`forge test`) before deploying.
