// Installed-client integration tests, not a substitute for the Microsoft-host smoke.
import assert from "node:assert/strict";
import { mkdtemp, chmod, writeFile, readFile, rm } from "node:fs/promises";
import { readlinkSync } from "node:fs";
import { createServer } from "node:net";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { test } from "node:test";
import { attestRuntime } from "../lib/headless-agent-host.mjs";

const launcher = resolve(
  import.meta.dirname,
  "../verify-headless-agent-host.sh",
);
const root = process.env.CADE_HEADLESS_TEST_ROOT;
const runtime = process.env.CADE_HEADLESS_TEST_RUNTIME;
const cleanPath = `${dirname(process.execPath)}:/usr/local/bin:/usr/bin:/bin`;
assert.ok(root, "Set CADE_HEADLESS_TEST_ROOT to a completed private bootstrap");
assert.ok(
  runtime,
  "Set CADE_HEADLESS_TEST_RUNTIME to the independently identified runtime",
);

async function exercise(context, reject) {
  const directory = await mkdtemp(join(tmpdir(), "cade-headless-installed-"));
  await chmod(directory, 0o700);
  const token = join(directory, "token");
  await writeFile(token, "SENSITIVE_SENTINEL_123456789", { mode: 0o600 });
  const sockets = new Set();
  const connections = [];
  const executables = [];
  const server = createServer((socket) => {
    sockets.add(socket);
    connections.push(true);
    socket.on("error", () => {
      socket.destroy();
    });
    socket.on("close", () => sockets.delete(socket));
    socket.on("data", () => {
      executables.push(readlinkSync(`/proc/${child.pid}/exe`));
      // A unit fixture rejecting the upgrade, never a custom AHP implementation.
      if (reject)
        socket.end(
          "HTTP/1.1 403 SENSITIVE_SENTINEL\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    });
  });
  context.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const child = spawn(
    "bash",
    [
      launcher,
      "--install-root",
      root,
      "--runtime-dir",
      runtime,
      "--token-file",
      token,
      "--endpoint",
      `ws://127.0.0.1:${server.address().port}`,
      "--timeout-ms",
      "30000",
    ],
    {
      env: { PATH: cleanPath },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  context.after(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
  });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (data) => stdout.push(data));
  child.stderr.on("data", (data) => stderr.push(data));
  const status = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(status, 1);
  assert.equal(connections.length, 1, "must reach the actual pinned transport");
  assert.ok(executables.length > 0);
  assert.deepEqual([...new Set(executables)], [process.execPath]);
  assert.equal(sockets.size, 0, "exited verifier must leave no open socket");
  assert.equal(Buffer.concat(stderr).toString(), "");
  const text = Buffer.concat(stdout).toString();
  assert.equal(text.includes("SENSITIVE_SENTINEL"), false);
  assert.equal(text.includes(directory), false);
  return JSON.parse(text);
}

test(
  "real pinned transport: HTTP auth rejection stays sanitized and disconnects",
  { timeout: 45000 },
  async (context) => {
    const result = await exercise(context, true);
    assert.equal(result.initialized, false);
    assert.equal(result.error, "connection-auth");
  },
);

test(
  "real pinned transport: stalled handshake times out and process releases socket",
  { timeout: 45000 },
  async (context) => {
    const result = await exercise(context, false);
    assert.equal(result.initialized, false);
    assert.equal(result.error, "timeout");
  },
);

test("runtime version and commit drift fail closed against the verified archive", async (context) => {
  const directory = await mkdtemp(join(tmpdir(), "cade-headless-drift-"));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(
    join(directory, "product.json"),
    JSON.stringify({ commit: "wrong" }),
  );
  await writeFile(
    join(directory, "package.json"),
    JSON.stringify({ version: "1.142.0" }),
  );
  await assert.rejects(attestRuntime(root, directory), /runtime-drift/);
  await writeFile(
    join(directory, "product.json"),
    JSON.stringify({ commit: "6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1" }),
  );
  await writeFile(
    join(directory, "package.json"),
    JSON.stringify({ version: "1.143.0" }),
  );
  await assert.rejects(attestRuntime(root, directory), /runtime-drift/);
  await writeFile(
    join(directory, "package.json"),
    JSON.stringify({ version: "1.142.0" }),
  );
  await assert.rejects(attestRuntime(root, directory), /runtime-integrity/);
});

test("tracked source and built-client tampering fail before import or network", async () => {
  for (const relative of ["src/client/index.ts", "proof-lib/index.js"]) {
    const file = join(root, "ahpx", relative);
    const original = await readFile(file);
    try {
      await writeFile(
        file,
        Buffer.concat([
          original,
          Buffer.from('\nthrow new Error("SENSITIVE_SENTINEL");\n'),
        ]),
      );
      const child = spawnSync(
        "bash",
        [
          launcher,
          "--install-root",
          root,
          "--runtime-dir",
          runtime,
          "--token-file",
          "/nonexistent",
          "--endpoint",
          "ws://127.0.0.1:1",
        ],
        {
          encoding: "utf8",
          timeout: 10000,
          env: { PATH: cleanPath },
        },
      );
      assert.equal(child.status, 1);
      assert.deepEqual(JSON.parse(child.stdout), {
        initialized: false,
        error: "client-integrity",
      });
      assert.equal(child.stderr, "");
      assert.equal(child.stdout.includes("SENSITIVE_SENTINEL"), false);
    } finally {
      await writeFile(file, original);
    }
  }
});
