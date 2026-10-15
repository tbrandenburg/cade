import assert from "node:assert/strict";
import {
  mkdtemp,
  writeFile,
  mkdir,
  chmod,
  symlink,
  rm,
  readFile,
  readdir,
  access,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import {
  argumentsFor,
  connectionToken,
  privatePath,
  discovery,
  errorCategory,
  attestRuntime,
} from "../lib/headless-agent-host.mjs";

const scripts = resolve(import.meta.dirname, "..");
const cleanPath = `${dirname(process.execPath)}:/usr/local/bin:/usr/bin:/bin`;
const args = [
  "--install-root",
  "/private/tools",
  "--runtime-dir",
  "/actual/server",
  "--token-file",
  "/private/token",
  "--endpoint",
  "ws://127.0.0.1:39873",
];
async function fixture(context) {
  const directory = await mkdtemp(join(tmpdir(), "cade-headless-test-"));
  await chmod(directory, 0o700);
  context.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test("validates loopback endpoints, explicit/default versions and bounded timeouts", () => {
  const options = argumentsFor(args);
  assert.equal(options.timeout, 60000);
  assert.equal(options.protocol, "0.10.0");
  assert.equal(
    argumentsFor([
      ...args.slice(0, -1),
      "ws://[::1]:1234/",
      "--protocol-version",
      "default",
    ]).protocol,
    "default",
  );
  assert.equal(argumentsFor([...args, "--timeout-ms", "100"]).timeout, 100);
});

test("rejects credentials, URL tricks and non-loopback hosts before network access", () => {
  for (const endpoint of [
    "ws://localhost:80",
    "ws://127.1:80",
    "ws://2130706433:80",
    "ws://0.0.0.0:80",
    "wss://127.0.0.1:80",
    "ws://user:secret@127.0.0.1:80",
    "ws://127.0.0.1:80/?tkn=secret",
    "ws://127.0.0.1:80/#secret",
    "ws://127.0.0.1:65536",
    "ws://127.0.0.1:80/other",
  ]) {
    assert.throws(
      () => argumentsFor([...args.slice(0, -1), endpoint]),
      /invalid-arguments/,
    );
    assert.equal(
      errorCategory(new Error("invalid-arguments")),
      "invalid-arguments",
    );
  }
});

test("rejects unknown/duplicate/missing options and malformed versions/timeouts", () => {
  for (const extra of [
    ["--timeout-ms", "NaN"],
    ["--timeout-ms", "0"],
    ["--timeout-ms", "120001"],
    ["--timeout-ms", "1e3"],
    ["--protocol-version", "0.10"],
    ["--protocol-version", "01.10.0"],
    ["--client-module", "/evil.mjs"],
    ["--endpoint", "ws://127.0.0.1:1"],
    ["--timeout-ms"],
  ]) {
    assert.throws(() => argumentsFor([...args, ...extra]), /invalid-arguments/);
  }
  assert.throws(() => argumentsFor([]), /invalid-arguments/);
  assert.throws(
    () => argumentsFor([...args.slice(0, 1), "relative", ...args.slice(2)]),
    /invalid-arguments/,
  );
});

test("reads a private token in process but refuses empty/oversized/unsafe files", async (context) => {
  const directory = await fixture(context);
  const file = join(directory, "token");
  await writeFile(file, "safe-fixture-token-123456\n", { mode: 0o600 });
  assert.equal(await connectionToken(file), "safe-fixture-token-123456");
  await chmod(file, 0o644);
  await assert.rejects(connectionToken(file), /unsafe-permissions/);
  await chmod(file, 0o600);
  await writeFile(file, "");
  await assert.rejects(connectionToken(file), /invalid-token-file/);
  await writeFile(file, "x".repeat(4097));
  await assert.rejects(connectionToken(file), /unsafe-permissions/);
  await assert.rejects(connectionToken(join(directory, "missing")), /ENOENT/);
});

test("refuses symlinks, directories and accessible token parents", async (context) => {
  const directory = await fixture(context);
  const file = join(directory, "token");
  await writeFile(file, "safe-fixture-token-123456", { mode: 0o600 });
  const link = join(directory, "link");
  await symlink(file, link);
  await assert.rejects(connectionToken(link), /ELOOP/);
  await assert.rejects(connectionToken(directory), /unsafe-permissions/);
  await chmod(directory, 0o755);
  await assert.rejects(connectionToken(file), /unsafe-permissions/);
  await assert.rejects(privatePath(directory, true), /unsafe-permissions/);
});

test("discovery reports only protocol, provider identifiers and numeric counts", () => {
  const secret = "SENSITIVE_SENTINEL";
  const result = {
    protocolVersion: "0.10.0",
    serverSeq: 5,
    snapshots: [{ resource: "ahp-root://", private: secret }],
    defaultDirectory: secret,
  };
  const client = {
    connected: true,
    state: {
      root: {
        agents: [
          {
            provider: "copilotcli",
            displayName: secret,
            models: [{ private: secret }],
            protectedResources: [{ private: secret }],
          },
          { provider: secret, models: [] },
        ],
      },
    },
  };
  const report = discovery(result, client, ["0.10.0"]);
  assert.deepEqual(report.agents, [
    { provider: "copilotcli", modelCount: 1 },
    { provider: "other", modelCount: 0 },
  ]);
  assert.equal(JSON.stringify(report).includes(secret), false);
  assert.equal(report.providerAuthenticationAttempted, false);
  assert.equal(report.sessionCreationAttempted, false);
  assert.equal(report.rootSnapshot, true);
});

test("refuses protocol mismatch, missing root snapshot and invalid discovery", () => {
  const result = {
    protocolVersion: "0.10.0",
    serverSeq: 5,
    snapshots: [{ resource: "ahp-root://" }],
  };
  const client = { connected: true, state: { root: { agents: [] } } };
  assert.throws(() => discovery(result, client, ["1.0.0"]), /protocol/);
  assert.throws(
    () => discovery({ ...result, snapshots: [] }, client, ["0.10.0"]),
    /protocol/,
  );
  assert.throws(
    () => discovery(result, { ...client, connected: false }, ["0.10.0"]),
    /protocol/,
  );
  assert.throws(
    () =>
      discovery(
        result,
        { connected: true, state: { root: { agents: [{ models: null }] } } },
        ["0.10.0"],
      ),
    /protocol/,
  );
});

test("categorizes raw library failures without returning URLs, paths or tokens", () => {
  for (const [message, category] of [
    [
      "connection ws://127.0.0.1/?tkn=SENSITIVE_SENTINEL failed: Unexpected server response: 403",
      "connection-auth",
    ],
    ["Unexpected server response: 401", "connection-auth"],
    [
      "connect ECONNREFUSED ws://127.0.0.1:40301/?tkn=SENSITIVE_SENTINEL",
      "connection-or-installation",
    ],
    [
      "connect ECONNREFUSED ws://127.0.0.1:1234/?tkn=SENSITIVE_SENTINEL401",
      "connection-or-installation",
    ],
    ["unsupported protocol version SENSITIVE_SENTINEL", "protocol"],
    ["ws://private/?tkn=SENSITIVE_SENTINEL timed out", "timeout"],
    ["/private/path/SENSITIVE_SENTINEL", "connection-or-installation"],
  ]) {
    assert.equal(errorCategory(new Error(message)), category);
    assert.equal(
      errorCategory(new Error(message)).includes("SENSITIVE_SENTINEL"),
      false,
    );
  }
});

test("runtime archive corruption is rejected before reading a caller runtime", async (context) => {
  const directory = await fixture(context);
  await writeFile(join(directory, "runtime.tar.gz"), "corrupted archive");
  await assert.rejects(
    attestRuntime(directory, join(directory, "missing")),
    /runtime-integrity/,
  );
  await chmod(join(directory, "runtime.tar.gz"), 0o644);
  await assert.rejects(
    privatePath(join(directory, "runtime.tar.gz")),
    /unsafe-permissions/,
  );
});

test("launcher sanitizes invalid arguments and drops inherited Node/debug credentials", () => {
  const child = spawnSync(
    "bash",
    [
      join(scripts, "verify-headless-agent-host.sh"),
      ...args,
      "--protocol-version",
      "SENSITIVE_SENTINEL",
    ],
    {
      encoding: "utf8",
      timeout: 10000,
      env: {
        PATH: cleanPath,
        NODE_OPTIONS: "--not-a-real-option=SENSITIVE_SENTINEL",
        AHPX_DEBUG_PROTOCOL: "1",
        AHPX_TOKEN: "SENSITIVE_SENTINEL",
        GH_TOKEN: "SENSITIVE_SENTINEL",
      },
    },
  );
  assert.equal(child.status, 1);
  assert.deepEqual(JSON.parse(child.stdout), {
    initialized: false,
    error: "invalid-arguments",
  });
  assert.equal(child.stderr, "");
  assert.equal(
    (child.stdout + child.stderr).includes("SENSITIVE_SENTINEL"),
    false,
  );
});

test("launchers preserve selected Node and sanitize even a supplied clean marker", async (context) => {
  const directory = await fixture(context);
  const log = join(directory, "node.jsonl");
  const probe = join(directory, "probe.cjs");
  await writeFile(
    probe,
    `require('node:fs').appendFileSync(${JSON.stringify(log)}, JSON.stringify({executable:process.execPath, version:process.versions.node, environment:process.env, args:process.argv.slice(2)}) + '\\n');`,
  );
  await writeFile(
    join(directory, "node"),
    `#!/bin/bash\n"${process.execPath}" "${probe}" "$@"\nexec "${process.execPath}" "$@"\n`,
    { mode: 0o700 },
  );
  const poison = join(directory, "poison.cjs");
  const executed = join(directory, "executed");
  await writeFile(
    poison,
    `require('node:fs').writeFileSync(${JSON.stringify(executed)}, 'SENSITIVE_SENTINEL');`,
  );
  for (const name of ["bootstrap", "verify"]) {
    const child = spawnSync(
      "/bin/bash",
      [join(scripts, `${name}-headless-agent-host.sh`), "--help"],
      {
        encoding: "utf8",
        timeout: 10000,
        env: {
          PATH: `${directory}:/usr/local/bin:/usr/bin:/bin`,
          CADE_CLEAN_ENV: "1",
          NODE_OPTIONS: `--require=${poison}`,
          GH_TOKEN: "SENSITIVE_SENTINEL",
          ANTHROPIC_API_KEY: "SENSITIVE_SENTINEL",
          AHPX_DEBUG_PROTOCOL: "1",
        },
      },
    );
    assert.equal(child.status, 0);
    assert.match(child.stdout, new RegExp(`^Usage: ${name}-headless`));
    assert.equal(child.stderr, "");
  }
  const records = (await readFile(log, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  // Two engine checks plus the real verifier entry point, not system Node.
  assert.equal(records.length, 3);
  for (const record of records) {
    assert.equal(record.executable, process.execPath);
    assert.equal(record.version, process.versions.node);
    assert.deepEqual(record.environment, {
      HOME: "/nonexistent",
      PATH: "/usr/local/bin:/usr/bin:/bin",
      PWD: process.cwd(),
      SHLVL: "1",
      _: process.execPath,
    });
  }
  await assert.rejects(access(executed), /ENOENT/);
  assert.equal(
    (await readFile(log, "utf8")).includes("SENSITIVE_SENTINEL"),
    false,
  );
});

test("rejected interpreter fails before bootstrap writes or verifier import", async (context) => {
  const directory = await fixture(context);
  const bin = join(directory, "bin");
  await mkdir(bin);
  // An executable refusing the engine probe exercises the launcher's failure path.
  await writeFile(join(bin, "node"), "#!/bin/bash\nexit 1\n", { mode: 0o700 });
  for (const name of ["bootstrap", "verify"]) {
    const child = spawnSync(
      "/bin/bash",
      [
        join(scripts, `${name}-headless-agent-host.sh`),
        "--install-root",
        join(directory, "new"),
      ],
      {
        encoding: "utf8",
        timeout: 10000,
        env: {
          PATH: `${bin}:/usr/bin:/bin`,
          CADE_CLEAN_ENV: "1",
          NODE_OPTIONS: "--not-a-real-option=SENSITIVE_SENTINEL",
          GH_TOKEN: "SENSITIVE_SENTINEL",
        },
      },
    );
    assert.equal(child.status, 1);
    assert.equal(child.stderr, "");
    assert.equal(
      child.stdout,
      name === "bootstrap"
        ? "bootstrap: Node.js >=20 is required\n"
        : '{"initialized":false,"error":"unsupported-node"}\n',
    );
    assert.deepEqual(await readdir(directory), ["bin"]);
  }
});

test("bootstrap build shebangs use selected Node without inherited credentials", async (context) => {
  const directory = await fixture(context);
  const bin = join(directory, "bin");
  await mkdir(bin);
  // Only the external download boundary is replaced; no network/install is attempted.
  // A forwarding executable keeps the fixture tool directory on bootstrap's PATH.
  await writeFile(
    join(bin, "node"),
    `#!/bin/bash\nexec "${process.execPath}" "$@"\n`,
    { mode: 0o700 },
  );
  await writeFile(
    join(bin, "npm"),
    `#!/usr/bin/env node\nconsole.log(JSON.stringify({executable:process.execPath, version:process.versions.node, environment:process.env}));\n`,
    { mode: 0o700 },
  );
  await writeFile(join(bin, "curl"), "#!/bin/bash\nnpm --version\nexit 1\n", {
    mode: 0o700,
  });
  const root = join(directory, "new");
  const child = spawnSync(
    "/bin/bash",
    [join(scripts, "bootstrap-headless-agent-host.sh"), "--install-root", root],
    {
      encoding: "utf8",
      timeout: 10000,
      env: {
        PATH: `${bin}:/usr/bin:/bin`,
        CADE_CLEAN_ENV: "1",
        NODE_OPTIONS: "--not-a-real-option=SENSITIVE_SENTINEL",
        GH_TOKEN: "SENSITIVE_SENTINEL",
        AHPX_DEBUG_PROTOCOL: "1",
      },
    },
  );
  assert.equal(child.status, 1);
  assert.match(child.stdout, /^bootstrap: failed/);
  assert.equal(child.stderr, "");
  const text = await readFile(join(root, "install.log"), "utf8");
  const report = JSON.parse(text.trim());
  assert.equal(report.executable, process.execPath);
  assert.equal(report.version, process.versions.node);
  assert.equal(report.environment.PATH, `${bin}:/usr/local/bin:/usr/bin:/bin`);
  assert.equal(report.environment.HOME, join(root, "home"));
  for (const key of [
    "CADE_CLEAN_ENV",
    "NODE_OPTIONS",
    "GH_TOKEN",
    "AHPX_DEBUG_PROTOCOL",
  ])
    assert.equal(report.environment[key], undefined);
  assert.equal(text.includes("SENSITIVE_SENTINEL"), false);
});

test("bootstrap refuses existing and unsafe parent directories without overwriting", async (context) => {
  const directory = await fixture(context);
  const existing = join(directory, "existing");
  await mkdir(existing);
  const first = spawnSync(
    "bash",
    [
      join(scripts, "bootstrap-headless-agent-host.sh"),
      "--install-root",
      existing,
    ],
    { encoding: "utf8", timeout: 10000 },
  );
  assert.equal(first.status, 1);
  assert.match(first.stdout, /^bootstrap: failed/);
  await chmod(directory, 0o755);
  const second = spawnSync(
    "bash",
    [
      join(scripts, "bootstrap-headless-agent-host.sh"),
      "--install-root",
      join(directory, "new"),
    ],
    { encoding: "utf8", timeout: 10000 },
  );
  assert.equal(second.status, 1);
  assert.match(second.stdout, /^bootstrap: failed/);
});
