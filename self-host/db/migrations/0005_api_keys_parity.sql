-- ============================================================
-- 0005 api_keys: card_build_notified, nullable created_by
-- Upstream: 20260916160000_card_build_notified.sql
--           20260916180000_card_build_notified_comment.sql (comment only)
--           20260525200000_fix_user_delete_cascade.sql (created_by)
-- ============================================================
-- card_build_notified is selected by API-key authentication on every request,
-- so without it every key is rejected as "Invalid or revoked API key".
-- NULL is the correct value for existing keys: the server then treats them as
-- having a listing it never recorded (see card-build-notify.ts).
-- ============================================================

ALTER TABLE public.api_keys
  ADD COLUMN IF NOT EXISTS card_build_notified text;

-- Hosted lets a key outlive the user who created it.
ALTER TABLE public.api_keys ALTER COLUMN created_by DROP NOT NULL;
ALTER TABLE public.api_keys DROP CONSTRAINT IF EXISTS api_keys_created_by_fkey;
ALTER TABLE public.api_keys ADD CONSTRAINT api_keys_created_by_fkey
  FOREIGN KEY (created_by) REFERENCES public.users(id) ON DELETE SET NULL;
