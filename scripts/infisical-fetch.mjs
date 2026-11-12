// CI and cloud fetches use explicitly scoped, read-only service tokens only.
import { appendFileSync, realpathSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

function splitNames(raw) {
  return String(raw ?? "")
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function stripTrailingSlash(url) {
  return String(url ?? "").replace(/\/+$/, "");
}

/** Verify the token's authority before a bulk endpoint that may ignore secretPath. */
export async function validateServiceToken({ siteUrl, token, projectId, environment, secretPath, fetchImpl = fetch, timeoutMs = 30_000 }) {
  if (!projectId || !token || /[\r\n]/.test(token)) throw new Error("Missing or invalid scoped Infisical service token configuration");
  let body;
  try {
    const res = await fetchImpl(`${siteUrl}/api/v2/service-token`, {
      method: "GET", headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) throw new Error(`Infisical service token metadata failed: HTTP ${res.status}`);
    body = await res.json();
  } catch {
    throw new Error("Infisical service token metadata unavailable");
  }
  const project = body?.projectId ?? (typeof body?.workspace === "string" ? body.workspace : body?.workspace?._id ?? body?.workspace?.id);
  const scopes = body?.scopes;
  if (project !== projectId || !Array.isArray(scopes) || scopes.length !== 1 ||
      scopes[0].environment !== environment || scopes[0].secretPath !== secretPath ||
      !Array.isArray(body.permissions) || body.permissions.length !== 1 || body.permissions[0] !== "read") {
    throw new Error("Infisical service token must have exactly the requested project, environment, folder and read-only permission");
  }
}

/** Read only this declared scope, with server reference expansion disabled. */
export async function listSecretsRaw({ siteUrl, token, projectId, environment, secretPath, fetchImpl = fetch, timeoutMs = 30_000 }) {
  const qs = new URLSearchParams({
    workspaceId: projectId,
    environment,
    secretPath,
    viewSecretValue: "true",
    expandSecretReferences: "false",
    include_imports: "false",
    recursive: "false",
  });
  const res = await fetchImpl(`${siteUrl}/api/v3/secrets/raw?${qs.toString()}`, {
    method: "GET",
    headers: { authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    throw new Error(`Infisical secrets list failed: HTTP ${res.status}`);
  }
  const body = await res.json();
  const values = new Map();
  for (const s of body?.secrets ?? []) {
    if (s && s.secretKey && s.secretValue) {
      values.set(s.secretKey, s.secretValue);
    }
  }
  return values;
}

/** Registers each LINE of the value as its own mask, and never the joined
 * value.
 *
 * `::add-mask::` is a workflow command the runner parses one LINE at a
 * time: it registers only the text up to the first newline, then echoes the
 * remaining lines of that same write to the job log as ordinary, unmasked
 * output.  So a command carrying a whole multi-line value is not merely
 * useless -- emitting it FIRST is the leak itself: the runner registers line
 * one and prints every line after it into a public log, before the per-line
 * commands that would have hidden them have run.  A wrapped base64 blob --
 * which is exactly what `base64` produces on both macOS and GNU coreutils
 * unless given `-b 0` / `-w 0` -- is the everyday shape of such a value.
 *
 * GitHub's own `secrets.*` machinery registers each line of a multi-line
 * secret as a separate mask; this does the same, so a signing certificate or
 * an ASC key routed through this action is scrubbed as thoroughly as it was
 * when the workflow read it from `secrets.*`.  A single-line value is its own
 * only line, so it still costs exactly one command.
 *
 * The `seen` set collapses a value whose lines repeat, and the `trim()`
 * guard keeps a blank trailing line from registering the empty string (which
 * would mask nothing and warn on some runner versions). */
export function maskValue(value, log) {
  const seen = new Set();
  for (const line of String(value).split(/\r?\n/)) {
    if (!line.trim() || seen.has(line)) continue;
    seen.add(line);
    log(`::add-mask::${line.replaceAll("%", "%25").replaceAll("\r", "%0D")}`);
  }
}

/** Appends one GitHub Actions multiline env-var entry.  The delimiter is
 * random per call so a value that happens to contain a fixed delimiter
 * string can never break the file for a later name. */
export function writeGithubEnvValue(path, name, value, appendFileImpl = appendFileSync) {
  if (!path) return;
  const delimiter = `INFISICAL_${randomUUID().replace(/-/g, "")}`;
  appendFileImpl(path, `${name}<<${delimiter}\n${value}\n${delimiter}\n`);
}

/** References are never expanded across scopes or passed as credentials. */
export const UNRESOLVED_REFERENCE = /\$\{[^}]+\}/;

export function isUnresolvedReference(value) {
  return UNRESOLVED_REFERENCE.test(String(value ?? "").trim());
}

/** Missing tokens permit explicit GH fallbacks; invalid scope always fails closed. */
export async function resolveVaultValues({ siteUrl, projectId, token, environment, secretPath, fetchImpl, log = () => {} }) {
  if (!token) return new Map();
  // Scope errors fail closed rather than disguising a broad token as a fallback.
  await validateServiceToken({ siteUrl, token, projectId, environment, secretPath, fetchImpl });
  try {
    return await listSecretsRaw({ siteUrl, token, projectId, environment, secretPath, fetchImpl });
  } catch {
    log(`::warning::Infisical fetch unavailable; using GitHub secret fallbacks only.`);
    return new Map();
  }
}

export function exportAscCredentials(values, { env, log }) {
  for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"]) {
    const value = values.get(name);
    if (!value || isUnresolvedReference(value)) throw new Error(`Missing or unresolved ${name} in Fleet-OPS prod /asc`);
    if (name !== "ASC_KEY_P8" && /[\r\n]/.test(value)) throw new Error(`Signing field ${name} must be single-line`);
  }
  const key = values.get("ASC_KEY_P8");
  // Staging receives the key on stdin, never argv or a persisted shell command.
  const staged = spawnSync("bash", [join(dirname(fileURLToPath(import.meta.url)), "ios-stage-asc-key.sh")], {
    input: key.endsWith("\n") ? key : `${key}\n`, env, encoding: "utf8",
  });
  if (staged.status !== 0) throw new Error("ASC key staging failed");
  for (const name of ["ASC_KEY_ID", "ASC_ISSUER_ID"]) {
    const value = values.get(name);
    maskValue(value, log);
    writeGithubEnvValue(env.GITHUB_ENV, name, value);
    writeGithubEnvValue(env.GITHUB_ENV, `APPLE_API_${name.slice(4)}`, value);
  }
  const encoded = Buffer.from(key).toString("base64");
  maskValue(encoded, log);
  writeGithubEnvValue(env.GITHUB_ENV, "APPLE_API_KEY_P8_BASE64", encoded);
}

export async function run({ env = process.env, fetchImpl = fetch, log = (line) => console.log(line) } = {}) {
  const names = splitNames(env.INFISICAL_NAMES);
  const required = new Set(splitNames(env.INFISICAL_REQUIRED));
  const siteUrl = stripTrailingSlash(env.INFISICAL_SITE_URL || "https://app.infisical.com");
  const projectId = env.INFISICAL_PROJECT_ID || "";
  const environment = env.INFISICAL_ENVIRONMENT || "prod";
  const secretPath = env.INFISICAL_SECRET_PATH || "/";
  const token = env.INFISICAL_SERVICE_TOKEN || "";
  const githubEnvPath = env.GITHUB_ENV || "";

  const vaultValues = await resolveVaultValues({ siteUrl, projectId, token, environment, secretPath, fetchImpl, log });

  if (env.INFISICAL_SHELL_FILE) {
    if (!token || !projectId) throw new Error("Cloud export requires a scoped service token");
    const entries = [];
    for (const [name, value] of vaultValues) {
      if (isUnresolvedReference(value)) throw new Error("Cloud export contains an unresolved secret reference");
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) continue;
      entries.push(`export ${name}='${String(value).replaceAll("'", "'\\''")}'`);
    }
    if (entries.length === 0) throw new Error("No shell-compatible secrets fetched");
    writeFileSync(env.INFISICAL_SHELL_FILE, `${entries.join("\n")}\n`, { mode: 0o600 });
    return;
  }

  if (env.INFISICAL_ASC_MODE === "true") {
    if (!token || secretPath !== "/asc" || environment !== "prod") throw new Error("ASC requires a scoped service token for Fleet-OPS prod /asc");
    exportAscCredentials(vaultValues, { env, log });
    return;
  }

  const missingRequired = [];
  const unresolved = [];
  for (const name of names) {
    let value = vaultValues.get(name) || "";
    if (!value) {
      value = env[`GH_FALLBACK_${name}`] || "";
    }
    if (!value) {
      const message = `${name} is empty after the Infisical ${environment} export and the GitHub secret fallback.`;
      if (required.has(name)) {
        missingRequired.push(name);
        log(`::error::${message}`);
      } else {
        log(`::warning::${message}`);
      }
      continue;
    }
    if (isUnresolvedReference(value)) {
      // Name the KEY only -- never the value, even though it is a reference.
      unresolved.push(name);
      log(`::error::${name} is still an unresolved Infisical secret reference after the ${environment} export; check the target exists and use a separate scoped token for the target folder.`);
      continue;
    }
    maskValue(value, log);
    writeGithubEnvValue(githubEnvPath, name, value);
  }

  if (unresolved.length > 0) {
    throw new Error(`Unresolved Infisical secret reference(s): ${unresolved.join(", ")}`);
  }

  if (missingRequired.length > 0) {
    throw new Error(`Missing required Infisical name(s): ${missingRequired.join(", ")}`);
  }
}

// Compare physical paths.  Node's ESM loader realpaths the entry module, so an
// invocation through a symlinked directory (macOS /var -> /private/var) never
// matches process.argv[1] when compared as text.
function isEntryModule() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

const isMain = isEntryModule();
if (isMain) {
  run().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exitCode = 1;
  });
}
