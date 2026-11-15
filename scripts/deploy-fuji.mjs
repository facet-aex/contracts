import { readFile, writeFile, mkdir } from "node:fs/promises";
import { loadEnvFile } from "node:process";
import { createPublicClient, createWalletClient, defineChain, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

try { loadEnvFile(); } catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const key = process.env.FACET_FUJI_DEPLOYER_PRIVATE_KEY;
if (!/^0x[a-f0-9]{64}$/iu.test(key ?? "")) throw new Error("Dedicated Fuji deployer key missing");
const owner = "0x9Ba67CbB2af751af5e874a7EB57691828F43658e";
const payer = "0xFA8cCB3C5145fca08f22675ea740e89B1D3a317f";
const rpc = process.env.FACET_FUJI_RPC_URL ?? "https://api.avax-test.network/ext/bc/C/rpc";
const chain = defineChain({ id: 43113, name: "Avalanche Fuji", nativeCurrency: { name: "AVAX", symbol: "AVAX", decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
const publicClient = createPublicClient({ chain, transport: http(rpc, { timeout: 15_000 }) });
if ((await publicClient.getChainId()) !== 43113) throw new Error("FUJI_CHAIN_MISMATCH");
const account = privateKeyToAccount(key);
if ((await publicClient.getBalance({ address: account.address })) === 0n) throw new Error("DEPLOYER_UNFUNDED");
const wallet = createWalletClient({ account, chain, transport: http(rpc, { timeout: 15_000 }) });
const artifact = JSON.parse(await readFile(new URL("../out/FacetUSD.sol/FacetUSD.json", import.meta.url), "utf8"));
const abi = artifact.abi;
const bytecode = artifact.bytecode.object;
if (!Array.isArray(abi) || !/^0x[a-f0-9]+$/iu.test(bytecode)) throw new Error("BUILD_ARTIFACT_INVALID");
await mkdir(new URL("../.facet-data/", import.meta.url), { recursive: true });
const pendingUrl = new URL("../.facet-data/deployment-pending.json", import.meta.url);
let hash;
try { hash = JSON.parse(await readFile(pendingUrl, "utf8")).hash; } catch (error) {
  if (error.code !== "ENOENT") throw error;
}
if (!hash) {
  hash = await wallet.deployContract({ abi, bytecode, args: [owner, payer] });
  await writeFile(pendingUrl, JSON.stringify({ chainId: 43113, hash, deployer: account.address, owner, payer }, null, 2) + "\n", { mode: 0o600 });
}
const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 120_000 });
if (receipt.status !== "success" || !receipt.contractAddress) throw new Error(`Deployment failed: ${hash}`);
const address = receipt.contractAddress;
const code = await publicClient.getCode({ address });
if (!code || code === "0x") throw new Error("DEPLOYED_CODE_MISSING");
const read = (functionName, args = []) => publicClient.readContract({ address, abi, functionName, args });
const [name, symbol, decimals, version, actualOwner, ownerBalance, payerBalance, totalSupply, unused] = await Promise.all([
  read("name"), read("symbol"), read("decimals"), read("version"), read("owner"),
  read("balanceOf", [owner]), read("balanceOf", [payer]), read("totalSupply"),
  read("authorizationState", [payer, `0x${"0".repeat(64)}`]),
]);
if (name !== "FACET USD" || symbol !== "fUSD" || decimals !== 6 || version !== "2" || actualOwner.toLowerCase() !== owner.toLowerCase() || ownerBalance !== 1_000_000_000n || payerBalance !== 100_000_000n || totalSupply !== 1_100_000_000n || unused !== false) throw new Error("DEPLOYED_TOKEN_VERIFICATION_FAILED");
const deployment = { network: "Avalanche Fuji C-Chain", chainId: 43113, contractAddress: address, deployer: account.address, owner, demoPayer: payer, transactionHash: hash, blockNumber: receipt.blockNumber.toString(), name, symbol, decimals, eip712Version: version, ownerInitialAtomic: ownerBalance.toString(), payerInitialAtomic: payerBalance.toString(), totalSupplyAtomic: totalSupply.toString(), verifiedAt: new Date().toISOString() };
await writeFile(new URL("../fuji-deployment.json", import.meta.url), JSON.stringify(deployment, null, 2) + "\n");
process.stdout.write(JSON.stringify(deployment, null, 2) + "\n");
