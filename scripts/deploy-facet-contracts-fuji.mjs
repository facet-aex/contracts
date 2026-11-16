import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { loadEnvFile } from 'node:process';
import { createPublicClient, createWalletClient, encodeDeployData, http, isAddress, keccak256 } from 'viem';
import { avalancheFuji } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

try { loadEnvFile(); } catch (error) { if (error.code !== 'ENOENT') throw error; }
const privateKey = process.env.FACET_FUJI_DEPLOYER_PRIVATE_KEY;
if (!/^0x[0-9a-f]{64}$/i.test(privateKey ?? '')) throw new Error('FACET_FUJI_DEPLOYER_PRIVATE_KEY missing');

function requiredAddress(name) {
  const value = process.env[name];
  if (!value || !isAddress(value) || /^0x0{40}$/i.test(value)) throw new Error(`${name} missing or invalid`);
  return value;
}

const treasury = requiredAddress('FACET_FEE_TREASURY');
const operator = requiredAddress('FACET_SETTLEMENT_OPERATOR');
const runnerSigner = requiredAddress('FACET_RUNNER_ADDRESS');
const registryOwner = requiredAddress('FACET_REGISTRY_OWNER');
const recorder = requiredAddress('FACET_RECEIPT_RECORDER');
const tokenAddress = '0xe7082a54a456dc4dfe0ceadcd0d0dce7d8ba176f';
const rpcUrl = process.env.FACET_FUJI_RPC_URL ?? 'https://api.avax-test.network/ext/bc/C/rpc';
const publicClient = createPublicClient({ chain: avalancheFuji, transport: http(rpcUrl, { timeout: 15_000 }) });
const account = privateKeyToAccount(privateKey);
const walletClient = createWalletClient({ account, chain: avalancheFuji, transport: http(rpcUrl, { timeout: 15_000 }) });
if (await publicClient.getChainId() !== 43113) throw new Error('FUJI_CHAIN_MISMATCH');
const tokenCode = await publicClient.getCode({ address: tokenAddress });
if (!tokenCode || tokenCode === '0x') throw new Error('FUSD_CODE_MISSING');
const deploymentUrl = new URL('../fuji-deployment.json', import.meta.url);
const existing = JSON.parse(await readFile(deploymentUrl, 'utf8'));
if (existing.chainId !== 43113 || existing.contractAddress.toLowerCase() !== tokenAddress) throw new Error('FUSD_METADATA_MISMATCH');
if (await publicClient.getBalance({ address: account.address }) < 10_000_000_000_000_000n) throw new Error('DEPLOYER_BALANCE_BELOW_0_01_AVAX');

const artifacts = [
  { key: 'actorRegistry', contract: 'FacetActorRegistry', args: [registryOwner], checks: { owner: registryOwner } },
  { key: 'feeSplitAndEscrow', contract: 'FacetFeeSplitAndEscrow', args: [tokenAddress, treasury, 500, runnerSigner, operator], checks: { token: tokenAddress, platformTreasury: treasury, platformFeeBps: 500, runnerSigner, settlementOperator: operator } },
  { key: 'receiptLog', contract: 'FacetReceiptLog', args: [runnerSigner, recorder], checks: { runnerSigner, recorder } },
];

const pendingDir = new URL('../.facet-data/fuji-contract-deployments/', import.meta.url);
await mkdir(pendingDir, { recursive: true });

async function artifactFor(name) {
  const artifact = JSON.parse(await readFile(new URL(`../out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));
  if (!Array.isArray(artifact.abi) || !/^0x[0-9a-f]+$/i.test(artifact.bytecode?.object ?? '')) throw new Error(`ARTIFACT_INVALID:${name}`);
  return { abi: artifact.abi, bytecode: artifact.bytecode.object };
}

async function verifiedReceipt(hash) {
  try { return await publicClient.getTransactionReceipt({ hash }); } catch { return null; }
}

async function deployOne(item) {
  const artifact = await artifactFor(item.contract);
  const pendingUrl = new URL(`${item.key}.json`, pendingDir);
  let pending;
  try { pending = JSON.parse(await readFile(pendingUrl, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const expectedArgs = JSON.stringify(item.args);
  if (pending) {
    if (pending.chainId !== 43113 || pending.deployer.toLowerCase() !== account.address.toLowerCase() || JSON.stringify(pending.constructorArgs) !== expectedArgs) throw new Error(`PENDING_DEPLOYMENT_CONFIG_MISMATCH:${item.key}`);
  } else {
    const data = encodeDeployData({ abi: artifact.abi, bytecode: artifact.bytecode, args: item.args });
    const request = await walletClient.prepareTransactionRequest({ account, chain: avalancheFuji, data });
    const serializedTransaction = await walletClient.signTransaction(request);
    pending = { chainId: 43113, deployer: account.address, constructorArgs: item.args, hash: keccak256(serializedTransaction), serializedTransaction };
    await writeFile(pendingUrl, JSON.stringify(pending, null, 2) + '\n', { mode: 0o600 });
  }
  let receipt = await verifiedReceipt(pending.hash);
  if (!receipt) {
    try { await walletClient.sendRawTransaction({ serializedTransaction: pending.serializedTransaction }); } catch { /* Existing or uncertain broadcast: reconcile by hash. */ }
    receipt = await publicClient.waitForTransactionReceipt({ hash: pending.hash, timeout: 120_000 });
  }
  if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`DEPLOYMENT_FAILED:${item.key}:${pending.hash}`);
  const code = await publicClient.getCode({ address: receipt.contractAddress });
  if (!code || code === '0x') throw new Error(`DEPLOYED_CODE_MISSING:${item.key}`);
  for (const [functionName, expected] of Object.entries(item.checks)) {
    const actual = await publicClient.readContract({ address: receipt.contractAddress, abi: artifact.abi, functionName });
    if (typeof actual === 'string' && typeof expected === 'string'
      ? actual.toLowerCase() !== expected.toLowerCase() : actual !== expected) throw new Error(`CONSTRUCTOR_CHECK_FAILED:${item.key}:${functionName}`);
  }
  return { address: receipt.contractAddress, transactionHash: pending.hash, blockNumber: receipt.blockNumber.toString(), artifact: `out/${item.contract}.sol/${item.contract}.json` };
}

const deployed = {};
for (const item of artifacts) {
  deployed[item.key] = await deployOne(item);
  process.stdout.write(`${item.key}: ${deployed[item.key].address} (${deployed[item.key].transactionHash})\n`);
}
await writeFile(deploymentUrl, JSON.stringify({ ...existing, ...deployed, facetContractsVerifiedAt: new Date().toISOString() }, null, 2) + '\n');
