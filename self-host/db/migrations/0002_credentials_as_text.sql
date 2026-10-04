-- ============================================================
-- 0002 credential columns: bytea -> text
-- Upstream: 20260524200000_gmail_token_exchange_schema_fixes.sql
-- ============================================================
-- The server and the CLI both store AES-256-GCM ciphertext as a base64url
-- STRING (IV(12) || ciphertext || tag(16), no padding), and decryptStoredToken()
-- expects that same string back. The hosted schema moved these columns to
-- text in May 2026 for exactly this reason. The original self-host schema
-- declared them bytea, so:
--
--   write: PostgREST casts the JSON string to bytea, storing its ASCII bytes;
--   read:  PostgREST returns bytea as "\x7333..." hex, which is not base64url,
--          and every IMAP/SMTP operation fails with "Failed to decode base64".
--
-- encode(col, 'escape') turns those ASCII bytes back into the exact string the
-- CLI wrote. It is lossless for any byte sequence (non-printable bytes become
-- \nnn escapes), so nothing is destroyed even if a value is not base64url;
-- such values could never have been decrypted anyway, and are reported below.
--
-- Skips any column that is already text (fresh installs after this migration
-- was written still pass through 0001's bytea shape; hand-patched installs may
-- have converted already).
-- ============================================================

DO $$
DECLARE
  col text;
  bad bigint;
BEGIN
  FOREACH col IN ARRAY ARRAY['imap_password', 'oauth_access_token', 'oauth_refresh_token'] LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'inboxes'
        AND column_name = col AND data_type = 'bytea'
    ) THEN
      EXECUTE format(
        'ALTER TABLE public.inboxes ALTER COLUMN %I TYPE text USING encode(%I, ''escape'')',
        col, col
      );
      RAISE INFO '0002: converted inboxes.% from bytea to text', col;
    END IF;

    -- Repair a hand conversion done as `USING col::text`, which stores the bytea
    -- hex rendering ("\x7333...") instead of the string. Real base64url never
    -- starts with a backslash, so only rows in that exact shape whose decoded
    -- bytes are themselves base64url are touched.
    EXECUTE format(
      'UPDATE public.inboxes SET %I = encode(decode(substr(%I, 3), ''hex''), ''escape'')
        WHERE %I ~ ''^\\x([0-9a-f]{2})+$''
          AND encode(decode(substr(%I, 3), ''hex''), ''escape'') ~ ''^[A-Za-z0-9_-]+$''',
      col, col, col, col
    );
    GET DIAGNOSTICS bad = ROW_COUNT;
    IF bad > 0 THEN
      RAISE INFO '0002: repaired % hex-rendered inboxes.% value(s)', bad, col;
    END IF;

    EXECUTE format(
      'SELECT count(*) FROM public.inboxes WHERE %I IS NOT NULL AND %I !~ ''^[A-Za-z0-9_-]+$''',
      col, col
    ) INTO bad;
    IF bad > 0 THEN
      RAISE WARNING '0002: % inbox row(s) have an inboxes.% value that is not base64url ciphertext. '
        'Those mailboxes cannot be decrypted; re-provision them with `mcpe provision-inbox`.', bad, col;
    END IF;
  END LOOP;
END
$$;
