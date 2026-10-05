-- ---------------------------------------------------------------------------
-- Server settings required by the stack. Runs first (00- prefix) on a fresh
-- volume, see also /etc/mysql/conf.d defaults in the mysql:8.0 image.
-- ---------------------------------------------------------------------------

-- The Icinga DB schema contains the stored function `get_sla_ok_percent()`.
-- Creating stored functions while binary logging is enabled normally
-- requires SUPER (or `log_bin_trust_function_creators=1`), and the `icinga`
-- user must not get SUPER.
SET PERSIST log_bin_trust_function_creators = 1;
