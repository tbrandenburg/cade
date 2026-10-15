import { constants, createReadStream } from "node:fs";
import { lstat, open, readFile, readdir, readlink } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { dirname, isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";

const commit = "a88f9ba25105661fd6a63de41559362ddb2bbbe5";
const runtimeCommit = "6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1";
const runtimeSha =
  "f1ee2833c6323ee03e49d46351e834c44811c53d14ba178f5debdb84a5eb7876";
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const fail = (category) => {
  throw new Error(category);
};

export function argumentsFor(args) {
  const options = { timeout: 60000, protocol: "0.10.0" };
  const names = {
    "--install-root": "root",
    "--runtime-dir": "runtime",
    "--token-file": "token",
    "--endpoint": "endpoint",
    "--timeout-ms": "timeout",
    "--protocol-version": "protocol",
  };
  const seen = new Set();
  for (let index = 0; index < args.length; index += 2) {
    const name = names[args[index]];
    const value = args[index + 1];
    if (!name || seen.has(name) || !value || value.startsWith("--"))
      fail("invalid-arguments");
    seen.add(name);
    options[name] = value;
  }
  for (const key of ["root", "runtime", "token"])
    if (!options[key] || !isAbsolute(options[key])) fail("invalid-arguments");
  if (
    !/^\d+$/.test(String(options.timeout)) ||
    Number(options.timeout) < 100 ||
    Number(options.timeout) > 120000
  )
    fail("invalid-arguments");
  options.timeout = Number(options.timeout);
  if (options.protocol !== "default" && !semver.test(options.protocol))
    fail("invalid-arguments");
  // Validate the original spelling too: URL canonicalization accepts numeric IPv4 aliases.
  if (
    !/^ws:\/\/(127\.0\.0\.1|\[::1\]):[1-9]\d{0,4}\/?$/.test(
      options.endpoint ?? "",
    )
  )
    fail("invalid-arguments");
  if (Number(options.endpoint.match(/:(\d+)\/?$/)[1]) > 65535)
    fail("invalid-arguments");
  return options;
}

export async function privatePath(path, directory = false) {
  const stat = await lstat(path);
  if (
    stat.uid !== process.getuid() ||
    stat.isSymbolicLink() ||
    (stat.mode & 0o777) !== (directory ? 0o700 : 0o600) ||
    !(directory ? stat.isDirectory() : stat.isFile())
  )
    fail("unsafe-permissions");
}

export async function connectionToken(path) {
  await privatePath(dirname(path), true);
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = await file.stat();
    if (
      !stat.isFile() ||
      stat.uid !== process.getuid() ||
      (stat.mode & 0o777) !== 0o600 ||
      stat.size > 4096
    )
      fail("unsafe-permissions");
    const token = (await file.readFile("utf8")).trim();
    if (!/^[A-Za-z0-9_-]{16,4096}$/.test(token)) fail("invalid-token-file");
    return token;
  } finally {
    await file.close();
  }
}

async function hash(path) {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(path)) digest.update(chunk);
  return digest.digest("hex");
}

async function tree(path, prefix = "") {
  const entries = await readdir(join(path, prefix), { withFileTypes: true });
  const files = [];
  // Hash sequentially to bound descriptors and memory for the server's large tree.
  for (const entry of entries) {
    const name = join(prefix, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await tree(path, name)));
      continue;
    }
    if (entry.isFile()) {
      files.push([name, await hash(join(path, name))]);
      continue;
    }
    if (entry.isSymbolicLink()) {
      files.push([name, `link:${await readlink(join(path, name))}`]);
      continue;
    }
    fail("runtime-integrity");
  }
  return files;
}

export async function attestRuntime(root, runtime) {
  if ((await hash(join(root, "runtime.tar.gz"))) !== runtimeSha)
    fail("runtime-integrity");
  const product = JSON.parse(
    await readFile(join(runtime, "product.json"), "utf8"),
  );
  const pkg = JSON.parse(await readFile(join(runtime, "package.json"), "utf8"));
  if (product.commit !== runtimeCommit || pkg.version !== "1.142.0")
    fail("runtime-drift");
  const reference = new Map(await tree(join(root, "runtime-reference")));
  const actual = new Map(await tree(runtime));
  if (
    actual.size !== reference.size ||
    [...reference].some(([name, digest]) => actual.get(name) !== digest)
  )
    fail("runtime-integrity");
  return {
    version: pkg.version,
    commit: runtimeCommit,
    archiveSha256: runtimeSha,
    comparedFiles: reference.size,
    mismatches: 0,
  };
}

function git(root, args) {
  return execFileSync("git", ["-C", join(root, "ahpx"), ...args], {
    encoding: "utf8",
    timeout: 10000,
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
}

export function discovery(result, client, offered) {
  if (
    !offered.includes(result.protocolVersion) ||
    !client.connected ||
    !Number.isSafeInteger(result.serverSeq) ||
    result.serverSeq < 0 ||
    !Array.isArray(result.snapshots) ||
    !result.snapshots.some((snapshot) => snapshot.resource === "ahp-root://")
  )
    fail("protocol");
  const agents = client.state.root.agents;
  if (!Array.isArray(agents)) fail("protocol");
  return {
    initialized: true,
    offeredProtocolVersions: offered,
    protocolVersion: result.protocolVersion,
    serverSeq: result.serverSeq,
    snapshotCount: result.snapshots.length,
    rootSnapshot: true,
    agentCount: agents.length,
    agents: agents.map((agent) => {
      // Unknown provider labels are omitted, not echoed from an untrusted peer.
      if (!Array.isArray(agent.models)) fail("protocol");
      return {
        provider: ["copilotcli", "claude"].includes(agent.provider)
          ? agent.provider
          : "other",
        modelCount: agent.models.length,
      };
    }),
    providerAuthenticationAttempted: false,
    sessionCreationAttempted: false,
  };
}

export function errorCategory(error) {
  const message = error instanceof Error ? error.message : "";
  if (/\bUnexpected server response:\s*(401|403)\b/.test(message))
    return "connection-auth";
  if (/protocol version|unsupportedprotocol/i.test(message)) return "protocol";
  if (/timeout|timed out/i.test(message)) return "timeout";
  return [
    "invalid-arguments",
    "unsafe-permissions",
    "invalid-token-file",
    "client-integrity",
    "runtime-integrity",
    "runtime-drift",
    "protocol",
  ].includes(message)
    ? message
    : "connection-or-installation";
}

async function main(args) {
  if (args.length === 1 && args[0] === "--help") {
    process.stdout.write(
      "Usage: verify-headless-agent-host.sh --install-root /private/tools --runtime-dir /actual/server --token-file /private/token --endpoint ws://127.0.0.1:PORT [--protocol-version 0.10.0|default] [--timeout-ms 60000]\n",
    );
    return;
  }
  // Discard library diagnostics, including asynchronous transport URLs/errors.
  const output = process.stdout.write.bind(process.stdout);
  process.stdout.write = () => true;
  process.stderr.write = () => true;
  const emit = (report) => output(`${JSON.stringify(report)}\n`);
  process.on("uncaughtException", () => {
    emit({ initialized: false, error: "connection-or-installation" });
    process.exit(1);
  });
  process.on("unhandledRejection", () => {
    emit({ initialized: false, error: "connection-or-installation" });
    process.exit(1);
  });
  let client;
  let timer;
  let offered;
  let report;
  let transportFailed = false;
  try {
    const options = argumentsFor(args);
    timer = setTimeout(() => {
      emit({ initialized: false, error: "timeout" });
      process.exit(1);
    }, options.timeout);
    await privatePath(options.root, true);
    if (
      git(options.root, ["rev-parse", "HEAD"]) !== commit ||
      git(options.root, ["status", "--porcelain", "--untracked-files=no"]) !==
        ""
    )
      fail("client-integrity");
    const expected = (
      await readFile(join(options.root, "client.sha256"), "utf8")
    ).trim();
    if (
      `${await hash(join(options.root, "ahpx/proof-lib/index.js"))}  proof-lib/index.js` !==
      expected
    )
      fail("client-integrity");
    const runtime = await attestRuntime(options.root, options.runtime);
    const token = await connectionToken(options.token);
    const url = new URL(options.endpoint);
    url.searchParams.set("tkn", token);
    const module = await import(
      pathToFileURL(join(options.root, "ahpx/proof-lib/index.js")).href
    );
    // This pinned dependency exports ESM only; require.resolve cannot resolve it.
    const official = await import(
      pathToFileURL(
        join(
          options.root,
          "ahpx/node_modules/@microsoft/agent-host-protocol/dist/types/index.js",
        ),
      ).href
    );
    offered =
      options.protocol === "default"
        ? [...official.SUPPORTED_PROTOCOL_VERSIONS]
        : [options.protocol];
    client = new module.AhpClient({
      ...(options.protocol === "default" ? {} : { protocolVersions: offered }),
      connectTimeout: options.timeout,
      requestTimeout: options.timeout,
    });
    client.on("error", () => {
      transportFailed = true;
    });
    const result = await client.connect(url.href);
    const discovered = discovery(result, client, offered);
    await client.disconnect();
    client = undefined;
    await attestRuntime(options.root, options.runtime);
    if (transportFailed) fail("connection-or-installation");
    const text = JSON.stringify({ ...discovered, runtime });
    if (text.includes(token)) fail("protocol");
    report = JSON.parse(text);
  } catch (error) {
    process.exitCode = 1;
    report = {
      initialized: false,
      error: errorCategory(error),
      ...(offered ? { offeredProtocolVersions: offered } : {}),
    };
  } finally {
    try {
      if (client) await client.disconnect();
    } catch {
      process.exitCode = 1;
      report = { initialized: false, error: "connection-or-installation" };
    }
    clearTimeout(timer);
  }
  emit(report);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main(process.argv.slice(2));
