// AFC-359 / AFC-459: asc-api.mjs resolves App Store Connect credentials from
// the environment first, then from Infisical through fleet-secrets, and keeps
// the key id and private key together.
//
// A path on disk is NOT a credential source:  ASC_KEY_PATH is ignored wherever
// it appears, so a stale or foreign path in an operator's shell can never
// decide which key signs a request.
//
// Runs asc-api.mjs against a local HTTP server with a FAKE fleet-secrets binary
// and a throwaway HOME.  The JWT header's kid proves which key id was used,
// and the signature is verified against the candidate keys, so a test never
// compares credential values.  No real secrets.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { createVerify, generateKeyPairSync } from "node:crypto";
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
const namedPem = pem();
const fake = join(root, "fleet-secrets");
const fakeLog = join(root, "fake.log");
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
require("fs").appendFileSync(${JSON.stringify(fakeLog)}, name + " " + folder + "\\n");
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
      let stderr = "";
      child.stderr.on("data", (d) => { stderr += d; });
      child.stdout.resume();
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
        resolve({ code, kid, iss, jwt, stderr });
      });
    });
  });
}

// Whether the request was signed with a given key.  The answer is a boolean,
// so a credential value is never compared in the shell.
function signedWith(jwt, key) {
  if (!jwt) return false;
  const [header, payload, signature] = jwt.split(".");
  const verifier = createVerify("SHA256");
  verifier.update(`${header}.${payload}`);
  verifier.end();
  try {
    return verifier.verify({ key, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
  } catch {
    return false;
  }
}

function vaultCalls() {
  try {
    return readFileSync(fakeLog, "utf8");
  } catch {
    return "";
  }
}

test("nothing in the environment:  id, issuer and key all come from /asc", async () => {
  const r = await run({});
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ASCKEY0001");
  assert.equal(r.iss, "issuer-from-asc");
  assert.ok(signedWith(r.jwt, ascPem), "the request was not signed with the /asc key");
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
  assert.ok(signedWith(r.jwt, otherPem), "the request was not signed with the key that belongs to the key id");
  assert.ok(!signedWith(r.jwt, ascPem), "the /asc key signed a request for another key id");
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

test("the environment wins over a named key file, and the vault is not consulted", async () => {
  //  A disk credential never overrides the environment:  a stale or foreign
  //  value in an operator's shell would sign the upload with the wrong key.
  writeFileSync(fakeLog, "");
  const namedFile = join(root, "named-key.p8");
  writeFileSync(namedFile, namedPem);
  const r = await run({
    ASC_KEY_ID: "ENVKEY0001",
    ASC_ISSUER_ID: "env-issuer",
    ASC_KEY_P8: otherPem,
    ASC_KEY_PATH: namedFile
  });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ENVKEY0001");
  assert.equal(r.iss, "env-issuer");
  assert.ok(signedWith(r.jwt, otherPem), "the request was not signed with the key from the environment");
  assert.ok(!signedWith(r.jwt, namedPem), "the named key file signed the request");
  assert.equal(vaultCalls(), "", "the vault was consulted although the environment was complete");
});

test("a named ASC_KEY_PATH is ignored entirely:  the credential comes from the vault", async () => {
  //  A file somebody names can never decide which key signs the upload.
  writeFileSync(fakeLog, "");
  const namedFile = join(root, "named-file.p8");
  writeFileSync(namedFile, namedPem);
  const r = await run({
    ASC_KEY_ID: "ASCKEY0001",
    ASC_ISSUER_ID: "issuer-from-asc",
    ASC_KEY_PATH: namedFile
  });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ASCKEY0001");
  assert.ok(signedWith(r.jwt, ascPem), "the request was not signed with the /asc key");
  assert.ok(!signedWith(r.jwt, namedPem), "the named key file signed the request");
});

test("a named ASC_KEY_PATH on its own is not a credential source", async () => {
  writeFileSync(fakeLog, "");
  const namedFile = join(root, "named-only.p8");
  writeFileSync(namedFile, namedPem);
  const r = await run({ ASC_KEY_PATH: namedFile });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "ASCKEY0001");
  assert.ok(signedWith(r.jwt, ascPem), "the request was not signed with the /asc key");
  assert.ok(!signedWith(r.jwt, namedPem), "the named key file signed the request");
});

test("the APPLE_API_* trio wins over ASC_KEY_P8 in the environment", async () => {
  //  The order is the rule:  the environment beats the vault, and the
  //  APPLE_API_* names are the first source.
  writeFileSync(fakeLog, "");
  const r = await run({
    APPLE_API_KEY_ID: "APPLEKEY001",
    APPLE_API_ISSUER_ID: "apple-issuer",
    APPLE_API_KEY_P8_BASE64: Buffer.from(ascPem, "utf8").toString("base64"),
    ASC_KEY_ID: "ENVKEY0001",
    ASC_ISSUER_ID: "env-issuer",
    ASC_KEY_P8: otherPem
  });
  assert.equal(r.code, 0);
  assert.equal(r.kid, "APPLEKEY001");
  assert.equal(r.iss, "apple-issuer");
  assert.ok(signedWith(r.jwt, ascPem), "the request was not signed with the APPLE_API_* key");
  assert.ok(!signedWith(r.jwt, otherPem), "the ASC_KEY_P8 key signed the request");
});

test("an ASC_KEY_P8 that is not a PEM private key is a credential error, not a stack trace", async () => {
  const r = await run({
    ASC_KEY_ID: "ENVKEY0001",
    ASC_ISSUER_ID: "env-issuer",
    ASC_KEY_P8: "not a private key at all"
  });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /ASC_KEY_P8 is set but is not a PEM private key/);
  assert.equal(r.kid, null);
});

test.after(() => rmSync(root, { recursive: true, force: true }));
