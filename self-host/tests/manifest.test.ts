// Static checks that keep the self-host schema from drifting behind the server.
// No database needed:
//
//   deno test --allow-read self-host/tests/
//
// The database-level proof (fresh install, upgrades, failure handling) is
// self-host/tests/migrations.sh; parity with the hosted schema is
// self-host/tests/schema-parity.sh.

import { assert, assertEquals } from "jsr:@std/assert@1";

const ROOT = decodeURIComponent(new URL("../../", import.meta.url).pathname);
const UPSTREAM_DIR = `${ROOT}supabase/migrations`;
const SELFHOST_DIR = `${ROOT}self-host/db/migrations`;
const MANIFEST = `${ROOT}self-host/db/upstream-migrations.tsv`;
const SERVER_DIR = `${ROOT}supabase/functions/mcp-server`;

function listSql(dir: string): string[] {
  return [...Deno.readDirSync(dir)]
    .filter((e) => e.isFile && e.name.endsWith(".sql"))
    .map((e) => e.name)
    .sort();
}

const upstream = listSql(UPSTREAM_DIR);
const selfhost = listSql(SELFHOST_DIR);
const selfhostVersions = new Set(selfhost.map((f) => f.slice(0, 4)));
const selfhostSql = selfhost.map((f) => Deno.readTextFileSync(`${SELFHOST_DIR}/${f}`)).join("\n");

type Entry = { file: string; disposition: string; detail: string; line: number };
const manifest: Entry[] = Deno.readTextFileSync(MANIFEST)
  .split("\n")
  .map((text, i) => ({ text, line: i + 1 }))
  .filter(({ text }) => text.trim() && !text.startsWith("#"))
  .map(({ text, line }) => {
    const [file, disposition, detail] = text.split("\t");
    return { file, disposition, detail: detail ?? "", line };
  });

Deno.test("every upstream migration is classified for self-host", () => {
  const listed = new Set(manifest.map((e) => e.file));
  const missing = upstream.filter((f) => !listed.has(f));
  assertEquals(
    missing,
    [],
    `New upstream migration(s) not classified in self-host/db/upstream-migrations.tsv:\n  ${missing.join("\n  ")}\n` +
      "Decide whether the self-host MCP server needs it. If it touches anything the server reads or writes, " +
      "port it as the next self-host/db/migrations/NNNN_*.sql and list it as ported/partial; otherwise list it as skipped with a reason.",
  );
});

Deno.test("the manifest lists no migration that does not exist, and none twice", () => {
  const stale = manifest.filter((e) => !upstream.includes(e.file)).map((e) => `line ${e.line}: ${e.file}`);
  assertEquals(stale, [], "manifest entries for files that are not in supabase/migrations");
  const seen = new Set<string>();
  const dupes = manifest.filter((e) => (seen.has(e.file) ? true : (seen.add(e.file), false))).map((e) => e.file);
  assertEquals(dupes, [], "duplicate manifest entries");
});

Deno.test("manifest entries are well-formed and point at real self-host migrations", () => {
  for (const e of manifest) {
    assert(["ported", "partial", "skipped"].includes(e.disposition), `line ${e.line}: bad disposition "${e.disposition}"`);
    assert(e.detail.trim().length > 0, `line ${e.line}: ${e.file} needs a reason/detail`);
    if (e.disposition !== "skipped") {
      const m = e.detail.match(/^(\d{4}(?:,\d{4})*):/);
      assert(m, `line ${e.line}: ${e.disposition} detail must start with the self-host migration number(s), e.g. "0003: ..."`);
      for (const v of m[1].split(",")) {
        assert(selfhostVersions.has(v), `line ${e.line}: self-host migration ${v} does not exist`);
      }
    }
  }
});

Deno.test("self-host migrations are numbered 0001.. without gaps or duplicates", () => {
  selfhost.forEach((f, i) => {
    assert(/^\d{4}_[a-z0-9_]+\.sql$/.test(f), `bad migration filename: ${f}`);
    assertEquals(f.slice(0, 4), String(i + 1).padStart(4, "0"), `expected migration ${i + 1} to be numbered ${String(i + 1).padStart(4, "0")}, found ${f}`);
  });
});

Deno.test("self-host migrations leave transactions to the runner and avoid Supabase-only objects", () => {
  for (const f of selfhost) {
    // Strip comments and dollar-quoted bodies so prose and plpgsql don't trip the checks.
    const code = Deno.readTextFileSync(`${SELFHOST_DIR}/${f}`)
      .replace(/--[^\n]*/g, "")
      .replace(/\$\$[\s\S]*?\$\$/g, "$$$$");
    assert(!/^\s*(BEGIN|COMMIT|ROLLBACK|START TRANSACTION)\b/im.test(code), `${f}: the runner wraps each migration in its own transaction; do not BEGIN/COMMIT`);
    assert(!/\bCONCURRENTLY\b/i.test(code), `${f}: CONCURRENTLY cannot run inside the migration transaction`);
    assert(!/\b(auth|extensions|cron|net|vault|storage)\.[a-z_]+/i.test(code), `${f}: references a Supabase-only schema`);
    assert(!/\bmoddatetime\b/i.test(code), `${f}: use public.set_updated_at(), there is no moddatetime extension`);
  }
});

// Tables/RPCs the server calls that self-host deliberately does not create.
// Each is reached only on a path that is disabled or not applicable on
// self-host, and the server treats an error there as non-fatal.
const INTENTIONALLY_ABSENT: Record<string, string> = {
  billing_email_sends: "usage-cap emails; only written when caps are enforced (USAGE_ENFORCEMENT_DISABLED=true)",
  usage_limit_events: "usage-cap enforcement; disabled",
  oauth_refresh_tokens: "hosted OAuth server; first-use path label lookup fails open, expired-key automation check only for OAuth-issued keys",
  emit_system_event: "hosted operator notification on automation auto-disable; caught and logged",
  workspace_action_allowance: "usage-cap enforcement; skipped by USAGE_ENFORCEMENT_DISABLED=true",
  reserve_action_usage: "usage-cap enforcement; skipped by USAGE_ENFORCEMENT_DISABLED=true",
  finalize_action_usage_reservation: "usage-cap enforcement; skipped by USAGE_ENFORCEMENT_DISABLED=true",
  record_usage_limit_event: "usage-cap enforcement; skipped by USAGE_ENFORCEMENT_DISABLED=true",
};

function serverReferences(kind: "from" | "rpc"): Set<string> {
  const names = new Set<string>();
  const re = kind === "from" ? /\.from\(\s*["']([a-z_]+)["']/g : /\.rpc\(\s*["']([a-z_]+)["']/g;
  for (const e of Deno.readDirSync(SERVER_DIR)) {
    if (!e.isFile || !e.name.endsWith(".ts") || e.name.endsWith(".test.ts")) continue;
    for (const m of Deno.readTextFileSync(`${SERVER_DIR}/${e.name}`).matchAll(re)) names.add(m[1]);
  }
  return names;
}

Deno.test("every table the server queries is created by a self-host migration or explicitly absent", () => {
  const tables = serverReferences("from");
  assert(tables.size > 10, "sanity: expected to find the server's tables");
  const missing = [...tables].filter((t) =>
    !new RegExp(`CREATE TABLE (IF NOT EXISTS )?public\\.${t}\\b`, "i").test(selfhostSql) && !(t in INTENTIONALLY_ABSENT)
  );
  assertEquals(missing, [], "the server queries table(s) that no self-host migration creates; port the upstream migration");
});

Deno.test("every RPC the server calls is created by a self-host migration or explicitly absent", () => {
  const rpcs = serverReferences("rpc");
  const missing = [...rpcs].filter((f) =>
    !new RegExp(`CREATE (OR REPLACE )?FUNCTION public\\.${f}\\b`, "i").test(selfhostSql) && !(f in INTENTIONALLY_ABSENT)
  );
  assertEquals(missing, [], "the server calls function(s) that no self-host migration creates");
});

Deno.test("the intentionally-absent list has no stale entries", () => {
  const used = new Set([...serverReferences("from"), ...serverReferences("rpc")]);
  const stale = Object.keys(INTENTIONALLY_ABSENT).filter((n) => !used.has(n));
  assertEquals(stale, [], "listed as intentionally absent but the server no longer uses it; remove it");
});

Deno.test("the compose file disables usage enforcement that the absent RPCs back", () => {
  const compose = Deno.readTextFileSync(`${ROOT}self-host/docker-compose.yml`);
  assert(/USAGE_ENFORCEMENT_DISABLED:\s*\$\{USAGE_ENFORCEMENT_DISABLED:-true\}/.test(compose));
});
