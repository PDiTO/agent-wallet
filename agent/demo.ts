// Local demo of the agent side of AgentWallet.
//
// The agent only holds a session key. It builds a v0.7 PackedUserOperation, signs the EntryPoint's
// userOpHash with that key, and a stand-in bundler submits it with EntryPoint.handleOps. There is no
// real bundler or mempool here; "simulate" is an eth_call of handleOps, which is roughly what a bundler
// does before accepting an operation.
//
// Run through scripts/demo.sh, which starts anvil and deploys everything first.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Abi,
  type Address,
  type Hex,
  BaseError,
  ContractFunctionRevertedError,
  concat,
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  formatEther,
  formatUnits,
  getAbiItem,
  http,
  pad,
  parseEther,
  toFunctionSelector,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

// ---------------------------------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------------------------------

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const deployment = JSON.parse(readFileSync(join(root, "deployments/local.json"), "utf8")) as Record<string, Address>;
const abiOf = (name: string): Abi =>
  JSON.parse(readFileSync(join(root, "out", `${name}.sol`, `${name}.json`), "utf8")).abi;

const walletAbi = abiOf("AgentWallet");
const entryPointAbi = abiOf("IEntryPoint");
const tokenAbi = abiOf("MockERC20");

// anvil dev keys. The agent key matches script/DeployLocal.s.sol.
const agent = privateKeyToAccount(
  (process.env.AGENT_PK as Hex | undefined) ??
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
);
const bundler = privateKeyToAccount("0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a");
const guardian = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");

const transport = http(process.env.RPC_URL ?? "http://127.0.0.1:8545");
const publicClient = createPublicClient({ chain: foundry, transport });
const bundlerClient = createWalletClient({ chain: foundry, transport, account: bundler });
const guardianClient = createWalletClient({ chain: foundry, transport, account: guardian });

const { entryPoint, account, token, vendor } = deployment;
if (agent.address !== deployment.agent) throw new Error("AGENT_PK does not match the deployed session key");

// ---------------------------------------------------------------------------------------------------
// Building and signing user operations
// ---------------------------------------------------------------------------------------------------

type Call = { target: Address; value: bigint; data: Hex };

type PackedUserOperation = {
  sender: Address;
  nonce: bigint;
  initCode: Hex;
  callData: Hex;
  accountGasLimits: Hex;
  preVerificationGas: bigint;
  gasFees: Hex;
  paymasterAndData: Hex;
  signature: Hex;
};

const EXECUTE_USER_OP = toFunctionSelector(getAbiItem({ abi: walletAbi, name: "executeUserOp" }) as never);
const SESSION_MODE: Hex = "0x01";

/** Two uint128 values in one bytes32, high then low, as v0.7 packs gas limits and fees. */
const packUint128s = (high: bigint, low: bigint): Hex => pad(toHex((high << 128n) | low), { size: 32 });

/** Session ops go through executeUserOp: selector followed by abi.encode(Call[]). */
function sessionCallData(calls: Call[]): Hex {
  const encoded = encodeAbiParameters(
    [
      {
        type: "tuple[]",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    [calls],
  );
  return concat([EXECUTE_USER_OP, encoded]);
}

async function buildSessionOp(calls: Call[]): Promise<{ op: PackedUserOperation; userOpHash: Hex }> {
  // Each session key has its own nonce lane: key = the session key's address.
  const nonce = (await publicClient.readContract({
    address: entryPoint,
    abi: entryPointAbi,
    functionName: "getNonce",
    args: [account, BigInt(agent.address)],
  })) as bigint;
  const fees = await publicClient.estimateFeesPerGas();

  const op: PackedUserOperation = {
    sender: account,
    nonce,
    initCode: "0x",
    callData: sessionCallData(calls),
    accountGasLimits: packUint128s(300_000n, 300_000n), // verificationGasLimit, callGasLimit
    preVerificationGas: 50_000n,
    gasFees: packUint128s(fees.maxPriorityFeePerGas, fees.maxFeePerGas),
    paymasterAndData: "0x",
    signature: "0x",
  };

  const userOpHash = (await publicClient.readContract({
    address: entryPoint,
    abi: entryPointAbi,
    functionName: "getUserOpHash",
    args: [op],
  })) as Hex;

  // EIP-191 personal_sign over the 32-byte hash, then 0x01 || sessionKey || r || s || v.
  const signature = await agent.signMessage({ message: { raw: userOpHash } });
  op.signature = concat([SESSION_MODE, agent.address, signature]);
  return { op, userOpHash };
}

// ---------------------------------------------------------------------------------------------------
// Submitting (the "bundler")
// ---------------------------------------------------------------------------------------------------

/** Turn an EntryPoint or AgentWallet revert into something readable. */
function explain(data: Hex): string {
  const outer = decodeErrorResult({ abi: entryPointAbi, data });
  if (outer.errorName === "FailedOpWithRevert") {
    const [, reason, inner] = outer.args as [bigint, string, Hex];
    const decoded = decodeErrorResult({ abi: walletAbi, data: inner });
    return `${reason}: ${decoded.errorName}(${decoded.args?.map(String).join(", ") ?? ""})`;
  }
  if (outer.errorName === "FailedOp") return String((outer.args as [bigint, string])[1]);
  return outer.errorName;
}

type Outcome = "succeeded" | "reverted in execution" | "rejected in validation";

/** Submit a session op and check it ended the way the scenario expects, so the demo fails loudly. */
async function submit(label: string, calls: Call[], expected: Outcome): Promise<void> {
  console.log(`\n> ${label}`);
  const outcome = await run(calls);
  if (outcome !== expected) throw new Error(`expected "${expected}", got "${outcome}"`);
}

async function run(calls: Call[]): Promise<Outcome> {
  const { op, userOpHash } = await buildSessionOp(calls);
  const request = {
    address: entryPoint,
    abi: entryPointAbi,
    functionName: "handleOps",
    args: [[op], bundler.address],
  } as const;

  // A bundler simulates before including. Validation failures stop here and cost the account nothing.
  try {
    await publicClient.simulateContract({ ...request, account: bundler });
  } catch (err) {
    const revert = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
    const data = (revert as ContractFunctionRevertedError | null)?.raw;
    console.log(`  rejected in validation, not submitted: ${data ? explain(data) : String(err)}`);
    return "rejected in validation";
  }

  const hash = await bundlerClient.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  let success = false;
  let actualGasCost = 0n;
  let reason = "";
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== entryPoint.toLowerCase()) continue;
    try {
      const ev = decodeEventLog({ abi: entryPointAbi, data: log.data, topics: log.topics });
      const args = ev.args as unknown as Record<string, unknown>;
      if (args.userOpHash !== userOpHash) continue;
      if (ev.eventName === "UserOperationEvent") {
        success = args.success as boolean;
        actualGasCost = args.actualGasCost as bigint;
      } else if (ev.eventName === "UserOperationRevertReason") {
        const decoded = decodeErrorResult({ abi: walletAbi, data: args.revertReason as Hex });
        reason = `${decoded.errorName}(${decoded.args?.map(String).join(", ") ?? ""})`;
      }
    } catch {
      // Not an event from the minimal interface; ignore.
    }
  }

  console.log(`  tx ${hash}`);
  console.log(`  handleOps gasUsed ${receipt.gasUsed}, op paid ${formatEther(actualGasCost)} ETH`);
  console.log(success ? "  op succeeded" : `  op included but reverted in execution: ${reason}`);
  return success ? "succeeded" : "reverted in execution";
}

// ---------------------------------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------------------------------

const transferData = (to: Address, amount: bigint): Hex =>
  encodeFunctionData({ abi: tokenAbi, functionName: "transfer", args: [to, amount] });

async function showState(): Promise<void> {
  const [tokenLeft, ethLeft, session, vendorTokens, vendorEth] = await Promise.all([
    publicClient.readContract({ address: account, abi: walletAbi, functionName: "getSpendLimit", args: [agent.address, token] }),
    publicClient.readContract({ address: account, abi: walletAbi, functionName: "getSpendLimit", args: [agent.address, "0x0000000000000000000000000000000000000000"] }),
    publicClient.readContract({ address: account, abi: walletAbi, functionName: "getSession", args: [agent.address] }),
    publicClient.readContract({ address: token, abi: tokenAbi, functionName: "balanceOf", args: [vendor] }),
    publicClient.getBalance({ address: vendor }),
  ]);
  const s = session as { callsUsed: number; maxCalls: number; gasSpent: bigint; gasBudget: bigint };
  console.log(
    `  remaining today: ${formatUnits((tokenLeft as [unknown, bigint])[1], 18)} TUSD, ${formatEther((ethLeft as [unknown, bigint])[1])} ETH | ` +
      `calls ${s.callsUsed}/${s.maxCalls} | gas budget used ${formatEther(s.gasSpent)}/${formatEther(s.gasBudget)} ETH | ` +
      `vendor has ${formatUnits(vendorTokens as bigint, 18)} TUSD, ${formatEther(vendorEth)} ETH`,
  );
}

console.log(`AgentWallet ${account}`);
console.log(`session key ${agent.address}`);
await showState();

await submit(
  "pay the vendor 25 TUSD",
  [{ target: token, value: 0n, data: transferData(vendor, 25n * 10n ** 18n) }],
  "succeeded",
);
await showState();

await submit(
  "batch: 10 TUSD and 0.05 ETH to the vendor",
  [
    { target: token, value: 0n, data: transferData(vendor, 10n * 10n ** 18n) },
    { target: vendor, value: parseEther("0.05"), data: "0x" },
  ],
  "succeeded",
);
await showState();

// Spend limits need block.timestamp, so they are enforced in execution: the op is included and pays gas.
await submit(
  "try to pay 80 TUSD (only 65 left today)",
  [{ target: token, value: 0n, data: transferData(vendor, 80n * 10n ** 18n) }],
  "reverted in execution",
);
await showState();

await submit(
  "try to send TUSD to the agent's own address via transferFrom",
  [
    {
      target: token,
      value: 0n,
      data: encodeFunctionData({ abi: tokenAbi, functionName: "transferFrom", args: [account, agent.address, 1n] }),
    },
  ],
  "rejected in validation",
);

await submit(
  "try to send 0.01 ETH to an address that is not on the allowlist",
  [{ target: agent.address, value: parseEther("0.01"), data: "0x" }],
  "rejected in validation",
);

console.log("\n> guardian pauses all sessions");
await publicClient.waitForTransactionReceipt({
  hash: await guardianClient.writeContract({ address: account, abi: walletAbi, functionName: "pauseSessions" }),
});

await submit(
  "pay the vendor 1 TUSD while paused",
  [{ target: token, value: 0n, data: transferData(vendor, 10n ** 18n) }],
  "rejected in validation",
);
await showState();
console.log("\nall outcomes matched");
