# FACET demo-token repository instructions

- This is an independent Foundry/npm repository for the fUSD Fuji testnet contract. It does not import sibling source or configuration.
- Chain ID is `43113`; contract deployment and owner are recorded in `fuji-deployment.json`. Do not silently redeploy or change the asset address used by Gateway, MCP and facilitator.
- The owner's address is `0x9Ba67CbB2af751af5e874a7EB57691828F43658e`. The local deployer/facilitator key has no owner rights.
- Keep all private keys in ignored local `.env` only. Do not print keys, add mainnet configuration or claim this token is USD-backed.
- Run `forge fmt --check`, `forge test` and `forge build` before a contract change. Any new deployment requires a new ADR and cross-service compatibility proof.
