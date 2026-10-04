// Unit tests for the self-host CLI's pure helpers.
//
//   deno test --allow-read self-host/tests/

import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { parsePort, resolveSecurity } from "../cli/mcpe.ts";

Deno.test("security defaults follow the well-known ports", () => {
  assertEquals(resolveSecurity("imap", 993, undefined), "tls");
  assertEquals(resolveSecurity("imap", 143, undefined), "starttls");
  assertEquals(resolveSecurity("smtp", 465, undefined), "tls");
  assertEquals(resolveSecurity("smtp", 587, undefined), "starttls");
  assertEquals(resolveSecurity("smtp", 25, undefined), "starttls");
});

Deno.test("an explicit flag wins over the port", () => {
  assertEquals(resolveSecurity("smtp", 587, "tls"), "tls");
  assertEquals(resolveSecurity("smtp", 2525, "STARTTLS"), "starttls");
  assertEquals(resolveSecurity("imap", 10993, "tls"), "tls");
});

Deno.test("a non-standard port without a flag is refused, not guessed", () => {
  assertThrows(() => resolveSecurity("smtp", 2525, undefined), Error, "--smtp-security");
  assertThrows(() => resolveSecurity("imap", 1143, undefined), Error, "--imap-security");
  // A bare `--smtp-security` with no value parses as "true".
  assertThrows(() => resolveSecurity("smtp", 2525, "true"), Error, "--smtp-security");
});

Deno.test("only tls and starttls are accepted (anything else would mean cleartext AUTH)", () => {
  for (const bad of ["ssl", "none", "", "plain"]) {
    assertThrows(() => resolveSecurity("smtp", 587, bad), Error, "must be one of");
  }
});

Deno.test("ports are validated", () => {
  assertEquals(parsePort("--smtp-port", "587"), 587);
  for (const bad of ["0", "65536", "abc", "587x", "-1"]) {
    assertThrows(() => parsePort("--smtp-port", bad), Error, "--smtp-port");
  }
});
