-- ============================================================
-- 0003 inboxes: connection security, provider/status/service checks
-- Upstream: 20260805160000_connection_security_and_diagnostics.sql (inboxes half)
--           20260526000004_enum_check_constraints_retention_and_index.sql (inboxes checks)
--           20260901140000_inboxes_gmail_service.sql
-- ============================================================
-- imap_security / smtp_security select the TLS handshake:
--   'tls'      implicit TLS from the first byte (IMAP 993, SMTP 465)
--   'starttls' plain connect, then upgrade with STARTTLS (IMAP 143, SMTP 587)
-- The server uses these values as given. It only infers from the port when
-- smtp_security is NULL, and never infers for IMAP, so 'tls' on port 587
-- attempts implicit TLS against a STARTTLS listener and hangs until timeout.
--
-- Existing rows are backfilled from their port, exactly as upstream did for
-- SMTP (587 -> starttls, else tls); IMAP 143 is likewise backfilled to
-- starttls, since implicit TLS on 143 could never have worked.
--
-- Hand-patched installs may already have these columns. Values already there
-- are an operator decision and are left alone, but rows whose port and mode
-- disagree are reported, because that combination is almost always the
-- residue of an `ADD COLUMN ... DEFAULT 'tls'` patch.
-- ============================================================

ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS imap_security text;
ALTER TABLE public.inboxes ADD COLUMN IF NOT EXISTS smtp_security text;

UPDATE public.inboxes
SET imap_security = CASE WHEN imap_port = 143 THEN 'starttls' ELSE 'tls' END
WHERE imap_security IS NULL;

UPDATE public.inboxes
SET smtp_security = CASE WHEN smtp_port = 587 THEN 'starttls' ELSE 'tls' END
WHERE smtp_security IS NULL;

ALTER TABLE public.inboxes
  ALTER COLUMN imap_security SET DEFAULT 'tls',
  ALTER COLUMN imap_security SET NOT NULL,
  ALTER COLUMN smtp_security SET DEFAULT 'tls',
  ALTER COLUMN smtp_security SET NOT NULL;

-- Upstream created the IMAP check inline, so Postgres named it
-- inboxes_imap_security_check; the SMTP one was named explicitly.
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_imap_security_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_imap_security_check
  CHECK (imap_security IN ('tls', 'starttls'));
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_smtp_security_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_smtp_security_check
  CHECK (smtp_security IN ('tls', 'starttls'));

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT email_address, 'SMTP' AS proto, smtp_port AS port, smtp_security AS mode
      FROM public.inboxes
     WHERE deleted_at IS NULL
       AND ((smtp_port = 587 AND smtp_security = 'tls') OR (smtp_port = 465 AND smtp_security = 'starttls'))
    UNION ALL
    SELECT email_address, 'IMAP', imap_port, imap_security
      FROM public.inboxes
     WHERE deleted_at IS NULL
       AND ((imap_port = 143 AND imap_security = 'tls') OR (imap_port = 993 AND imap_security = 'starttls'))
  LOOP
    RAISE WARNING '0003: inbox % uses % port % with security=%, which usually hangs or fails. '
      'Fix it with: mcpe set-security --inbox % --%-security %',
      r.email_address, r.proto, r.port, r.mode,
      r.email_address, lower(r.proto), CASE WHEN r.mode = 'tls' THEN 'starttls' ELSE 'tls' END;
  END LOOP;
END
$$;

-- ── provider / status / service checks (hosted parity) ───────────────────────
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_provider_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_provider_check
  CHECK (provider IN ('gmail', 'outlook', 'fastmail', 'imap'));

ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_status_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_status_check
  CHECK (status IN ('pending', 'active', 'error', 'revoked'));

-- 'gmail' here is a Google app password over IMAP/SMTP, not the OAuth provider.
ALTER TABLE public.inboxes DROP CONSTRAINT IF EXISTS inboxes_service_check;
ALTER TABLE public.inboxes ADD CONSTRAINT inboxes_service_check
  CHECK (service IS NULL OR service IN ('icloud', 'yahoo', 'zoho', 'yandex', 'generic', 'fastmail', 'gmail'));
