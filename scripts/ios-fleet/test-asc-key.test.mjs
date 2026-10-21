// The App Store Connect private key:  how it is validated, how it is staged,
// and how it reaches the client.
//
// The private key is a secret, and the approved secret sources are the process
// environment, a captured `fleet-secrets get NAME` and bootstrap-only Keychain
// credentials.  A caller-supplied file is not one of them, so nothing reads a
// key file:  the key travels in the environment, and the file this module
// writes is a staging copy for the Apple tools that need a key on disk.
//
// Everything here is synthetic:  the keys are generated at test time and are
// never committed, and nothing reaches the network.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { generateKeyPairSync } from "node:crypto";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { CLIENT_ENV_ALLOWLIST, clientEnvironment, normalizePrivateKey } from "./asc-key.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const helper = join(here, "asc-key.mjs");
const client = join(here, "asc-api.mjs");
const root = mkdtempSync(join(tmpdir(), "asc-key-test-"));
//  A PATH with node and nothing else:  the fleet reader lives in the operator's
//  own bin directory, and a test must never reach it or Infisical.
const safePath = [dirname(process.execPath), "/usr/bin", "/bin"].join(":");
//  A secret that has nothing to do with App Store Connect.  It is in the
//  environment of the parent on purpose, so the tests can show that it does
//  not reach the client.
const unrelatedSecret = "unrelated-runtime-secret-4f1c9a";

const keyPem = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

function staged(name, content = keyPem, mode = 0o600) {
  const path = join(root, name);
  writeFileSync(path, content);
  chmodSync(path, mode);
  return path;
}

function run(args, stdin = "", env = undefined) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [helper, ...args], {
      ...(env ? { env } : {}),
      stdio: ["pipe", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(stdin);
  });
}

test("a generated key is accepted and comes back with a trailing newline", () => {
  const normalized = normalizePrivateKey(keyPem);
  assert.ok(normalized, "a real key was refused");
  assert.ok(normalized.endsWith("\n"), "the key has to end with a newline");
  assert.equal(normalized.trim(), keyPem.trim());
});

test("a malformed PEM is refused, because the envelope is not a key", () => {
  //  A truncated key, an armored block and a mangled export all carry the
  //  envelope and still fail to parse.  Accepting them would hand the signer
  //  something it cannot use, and the failure would come back as a stack
  //  trace instead of a credential error.
  assert.equal(normalizePrivateKey("-----BEGIN PRIVATE KEY-----\nnot base64 at all\n-----END PRIVATE KEY-----\n"), null); // gitleaks:allow
  assert.equal(normalizePrivateKey("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n"), null); // gitleaks:allow
  assert.equal(normalizePrivateKey(""), null);
  assert.equal(normalizePrivateKey(undefined), null);
  assert.equal(normalizePrivateKey("hunter2"), null);
});

test("the key never travels in the command arguments", async () => {
  //  The key goes in on stdin, and the command reports the status of it
  //  without printing it, so it is never an argument of any process and never
  //  on stdout.
  const result = await run(["validate"], keyPem);
  assert.equal(result.code, 0);
  assert.match(result.stdout, /is a PEM private key/, `the status was not reported:\n${result.stdout}`);
  assert.doesNotMatch(result.stdout, /PRIVATE KEY/, "the key reached stdout");
  assert.ok(!result.stderr.includes("PRIVATE KEY"), "the key envelope reached a log line");
});

test("the command line refuses a value that is not a key", async () => {
  const result = await run(["validate"], "not a private key");
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /not a PEM private key/);
});

test("the command line has no way to read a key file", async () => {
  //  A path is not an approved secret source, so the command line has no
  //  command that reads one:  the key comes from the environment or from
  //  fleet-secrets, and nowhere else.
  const path = staged("no-reader.p8");
  const read = await run(["read", path]);
  assert.notEqual(read.code, 0, "the command line read a key file");
  assert.match(read.stderr, /usage/);
  assert.equal(read.stdout, "", "a refused command must not put anything on stdout");
  const exec = await run(["exec", path, "--", process.execPath, "-e", "process.exit(0)"]);
  assert.notEqual(exec.code, 0, "the command line handed a key file to a child");
  assert.match(exec.stderr, /usage/);
});

test("the command line writes a key to a file only its owner can read", async () => {
  const path = join(root, "written.p8");
  const result = await run(["write", path], keyPem);
  assert.equal(result.code, 0, `the write failed: ${result.stderr}`);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(readFileSync(path, "utf8").trim(), keyPem.trim());
});

test("the command line refuses to write a value that is not a key", async () => {
  const path = join(root, "refused.p8");
  const result = await run(["write", path], "not a private key");
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /not a PEM private key/);
});

test("the child's environment is an allowlist, not a copy of the parent's", () => {
  //  A wholesale copy of the parent's environment hands every credential on
  //  the operator's machine to the child, including the ones that have
  //  nothing to do with App Store Connect.
  const child = clientEnvironment({
    PATH: "/usr/bin",
    HOME: "/tmp/home",
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    UNRELATED_RUNTIME_SECRET: unrelatedSecret
  }, { ASC_KEY_P8: keyPem });
  assert.equal(child.UNRELATED_RUNTIME_SECRET, undefined, "an unrelated secret reached the child");
  assert.equal(child.ASC_KEY_P8.trim(), keyPem.trim(), "the key was not handed over");
  assert.equal(child.ASC_KEY_ID, "SYNTHETICKEYID1");
  assert.deepEqual(Object.keys(child).sort(), ["ASC_ISSUER_ID", "ASC_KEY_ID", "ASC_KEY_P8", "HOME", "PATH"]);
  //  Every variable the child gets is on the allowlist.
  for (const name of Object.keys(child)) {
    assert.ok(CLIENT_ENV_ALLOWLIST.includes(name) || name === "ASC_KEY_P8",
      `${name} crossed over and is not on the allowlist`);
  }
});

// A server that answers the endpoints the client walks.
//
// Every request is held open until the test releases it, so the client is
// still alive, with its credential in its environment, while the process
// table is read.  The `firstRequest` promise is the readiness signal:  it
// settles when a request has arrived, which is after the client has built
// its environment and sent it.
function localServer({ hold = false } = {}) {
  const seen = [];
  const pending = [];
  let holding = hold;
  let signal = null;
  const firstRequest = new Promise((resolve) => { signal = resolve; });
  const respond = (req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ data: [] }));
  };
  const server = createServer((req, res) => {
    seen.push({ url: req.url, authorization: req.headers.authorization || "" });
    signal();
    if (holding) {
      pending.push(() => respond(req, res));
      return;
    }
    respond(req, res);
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({
      base: `http://127.0.0.1:${server.address().port}`,
      seen,
      firstRequest,
      //  Releasing answers every request that is held and stops holding the
      //  ones that come after it, so a client that asks for more than once
      //  can finish.
      releaseAll: () => {
        holding = false;
        while (pending.length > 0) pending.shift()();
      },
      close: () => server.close()
    }));
  });
}

function spawnNode(args, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

// Spawns the client and hands back its pid, so the process table can be read
// while it is waiting on App Store Connect.
function spawnTracked(args, env) {
  const child = spawn(process.execPath, args, { env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => { stdout += d; });
  child.stderr.on("data", (d) => { stderr += d; });
  const done = new Promise((resolve) => {
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
  return {
    pid: child.pid,
    done,
    kill: () => { try { child.kill("SIGKILL"); } catch { /* already gone */ } }
  };
}

// The environment of another process is NOT read here.  On macOS `ps -E`
// prints it and on Linux it sits in /proc/<pid>/environ, and either way the
// dump carries the private key and every unrelated credential the operator
// has.  The handoff is proved by the SIGNED REQUEST the client makes with
// the key:  a request whose JWT carries the key id can only be signed with
// the key that was handed over.
function jwtKeyId(authorization) {
  const token = String(authorization || "").replace(/^Bearer /, "");
  if (!token) return null;
  return JSON.parse(Buffer.from(token.split(".")[0], "base64url").toString()).kid;
}

test("the client reports the ASC_KEY_P8 environment source", async () => {
  const server = await localServer();
  try {
    const result = await spawnNode([client, "GET", `${server.base}/v1/apps`], {
      PATH: safePath,
      HOME: join(root, "home-client"),
      ASC_API_BASE: server.base,
      ASC_KEY_ID: "SYNTHETICKEYID1",
      ASC_ISSUER_ID: "synthetic-issuer",
      ASC_KEY_P8: keyPem
    });
    assert.match(result.stderr, /asc-auth: using ASC_KEY_P8 environment/,
      `the client did not report the environment source:\n${result.stderr}`);
    assert.equal(jwtKeyId(server.seen[0].authorization), "SYNTHETICKEYID1",
      "the request was not signed with the key from the environment");
    assert.doesNotMatch(result.stdout + result.stderr, /BEGIN PRIVATE KEY/,
      "the key reached the client's output");
  } finally {
    server.close();
  }
});

test("with no key in the environment and no fleet secret the client reports that it has no credential", async () => {
  const result = await spawnNode([client, "GET", "http://127.0.0.1:1/v1/apps"], {
    //  A bare PATH and a throwaway HOME keep the fleet reader out of the way,
    //  so the client really has no source left.
    PATH: "/usr/bin:/bin",
    HOME: join(root, "home-empty"),
    ASC_API_BASE: "http://127.0.0.1:1",
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer"
  });
  assert.equal(result.code, 1, `expected the refusal exit, got ${result.code}: ${result.stderr}`);
  assert.match(result.stderr, /no App Store Connect credential found/);
  //  The refusal names the sources that are approved, and says that a path
  //  is not one of them.
  assert.match(result.stderr, /APPLE_API_KEY_ID \/ APPLE_API_ISSUER_ID \/ APPLE_API_KEY_P8_BASE64/);
  assert.match(result.stderr, /ASC_KEY_ID \/ ASC_ISSUER_ID \/ ASC_KEY_P8/);
  assert.match(result.stderr, /A path in ASC_KEY_PATH is not a credential source/);
});

test("the key never reaches argv, and the child's environment carries it", async () => {
  const needle = keyPem.split("\n").find((line) => line.length > 32);
  const home = join(root, "home-argv");
  mkdirSync(home, { recursive: true });
  const server = await localServer({ hold: true });
  const env = {
    PATH: safePath,
    HOME: home,
    ASC_API_BASE: server.base,
    ASC_KEY_ID: "SYNTHETICKEYID1",
    ASC_ISSUER_ID: "synthetic-issuer",
    ASC_KEY_P8: keyPem
  };
  const app = spawnTracked([client, "GET", `${server.base}/v1/apps`], env);
  try {
    //  The request arriving is the readiness signal:  the client has built
    //  its environment and sent it, so it is alive with the credential in it.
    await server.firstRequest;
    //  While the client is waiting on App Store Connect, no process may
    //  carry the key in its command line.
    const table = execFileSync("ps", ["-A", "-o", "args="], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    assert.ok(!table.includes(needle), "the key reached a command line");
    //  The client is holding the key in its environment by design, so the
    //  environment of another process is never read:  the delivery is proved
    //  by the signed request below, not by a dump of a live process.
    server.releaseAll();
    const result = await app.done;
    assert.equal(result.code, 0, `the client failed: ${result.stderr}`);
    assert.ok(server.seen.some((entry) => jwtKeyId(entry.authorization) === "SYNTHETICKEYID1"),
      "the request was not signed with the key from the environment");
  } finally {
    server.releaseAll();
    app.kill();
    server.close();
  }
});
