// AFC-359: asc-api.mjs resolves App Store Connect credentials from the environment first,
// then from Infisical through fleet-secrets, and keeps the key id and private key together.
// Runs asc-api.mjs against a local HTTP server with a FAKE fleet-secrets binary and a
// throwaway HOME.  The JWT header's kid proves which key id was used.  No real secrets.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "asc-api.mjs");
const pem = () => generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey
  .export({ type: "pkcs8", format: "pem" });

const root = mkdtempSync(join(tmpdir(), "asc-js-test-"));
const home = join(root, "home");
mkdirSync(home);
const ascPem = pem();
const otherPem = pem();
const fake = join(root, "fleet-secrets");
writeFileSync(fake, `#!/usr/bin/env node
const [, , verb, name, , folder] = process.argv;
const table = {
  "/asc:ASC_KEY_ID": "ASCKEY0001",
  "/asc:ASC_ISSUER_ID": "issuer-from-asc",
  "/asc:ASC_KEY_P8": ${JSON.stringify(ascPem)},
  "/authkey-otherkey01-p8:AUTHKEY_OTHERKEY01": ${JSON.stringify(otherPem)},
};
const v = verb === "get" ? table[folder + ":" + name] : undefined;
if (v === undefined) process.exit(3);
process.stdout.write(v + "\\n");
`);
chmodSync(fake, 0o755);

function run(env) {
  return new Promise((resolve) => {
    const seen = [];
    const server = createServer((req, res) => {
      seen.push(req.headers.authorization || "");
      res.setHeader("content-type", "application/json");
      res.end("{\"data\":[]}");
    });
    server.listen(0, "127.0.0.1", () => {
      const url = `http://127.0.0.1:${server.address().port}/v1/apps`;
      const base = { PATH: process.env.PATH, HOME: home, FLEET_SECRETS: fake };
      const child = spawn(process.execPath, [script, "GET", url], { env: { ...base, ...env }, stdio: ["ignore", "pipe", "pipe"] });
      child.stdout.resume();
      child.stderr.resume();
      child.on("close", (code) => {
        server.close();
        const jwt = (seen[0] || "").replace(/^Bearer /, "");
        let kid = null;
        let iss = null;
        if (jwt) {
          const part = (i) => JSON.parse(Buffer.from(jwt.split(".")[i], "base64url").toString());
          kid = part(0).kid;
          iss = part(1).iss;
        }
        resolve({ code, kid, iss });
      });
    });
  });
}

test("nothing in the environment:  id, issuer and key all come from /asc", async () => {
  const r = await run({});
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ASCKEY0001");
  assert.equal(r.iss, "issuer-from-asc");
});

test("an env key id equal to the /asc one is served from /asc", async () => {
  const r = await run({ ASC_KEY_ID: "ASCKEY0001" });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ASCKEY0001");
});

test("an env key id that is not the /asc one gets its own .p8 and its own issuer, never the /asc pair", async () => {
  const r = await run({ ASC_KEY_ID: "OTHERKEY01", ASC_ISSUER_ID: "issuer-other" });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "OTHERKEY01");
  assert.equal(r.iss, "issuer-other");
});

test("an env key id that is not the /asc one with no env issuer fails closed", async () => {
  const r = await run({ ASC_KEY_ID: "OTHERKEY01" });
  assert.notEqual(r.code, 0);
  assert.equal(r.kid, null);
});

test("an env key id with no key material anywhere fails closed", async () => {
  const r = await run({ ASC_KEY_ID: "NOSUCHKEY0", ASC_ISSUER_ID: "any-issuer" });
  assert.notEqual(r.code, 0);
  assert.equal(r.kid, null);
});

test("a complete environment (id, issuer, key file) wins and never calls fleet-secrets", async () => {
  const keyFile = join(root, "env-key.p8");
  writeFileSync(keyFile, pem());
  const r = await run({ ASC_KEY_ID: "ENVKEY0001", ASC_ISSUER_ID: "env-issuer", ASC_KEY_PATH: keyFile, FLEET_SECRETS: join(root, "does-not-exist") });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ENVKEY0001");
  assert.equal(r.iss, "env-issuer");
});

test("only a leading ~/ is expanded in ASC_KEY_PATH", async () => {
  writeFileSync(join(home, "tilde-key.p8"), pem());
  const gone = join(root, "does-not-exist");
  const ok = await run({ ASC_KEY_ID: "TILDEKEY01", ASC_ISSUER_ID: "tilde-issuer", ASC_KEY_PATH: "~/tilde-key.p8", FLEET_SECRETS: gone });
  assert.equal(ok.code, 0);
  assert.equal(ok.kid, "TILDEKEY01");
  const bad = await run({ ASC_KEY_ID: "TILDEKEY01", ASC_ISSUER_ID: "tilde-issuer", ASC_KEY_PATH: "~other/tilde-key.p8", FLEET_SECRETS: gone });
  assert.notEqual(bad.code, 0);
});

test.after(() => rmSync(root, { recursive: true, force: true }));
