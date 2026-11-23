#!/usr/bin/env python3
"""Run with python3 -I /absolute/path/run_backend_tests.py [--red].
Creates and destroys its OWN Unix-socket-only PostgreSQL cluster; never uses .env,
a cloud URL, an existing cluster, Docker, downloaded archives, or Supabase link state.
Auth/storage/pg_net are offline shims. Real SQL, triggers, RLS, and RPCs execute.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

TESTS = Path(__file__).resolve().parent
MIGRATIONS = TESTS.parent / "migrations"
NEW = ["20261123000000_protect_profile_roles.sql", "20261123000001_shipping_settings.sql"]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--red", action="store_true", help="Run pre-change schema and expect the missing behaviors to fail")
    args = parser.parse_args()
    for name in NEW:
        statements = (MIGRATIONS / name).read_text().splitlines()
        if any(line.strip().upper() in ("BEGIN;", "COMMIT;") for line in statements):
            raise RuntimeError(f"Migration must not commit its caller-owned transaction: {name}")
    print("PASS: both new migrations leave transaction ownership to CLI/harness/psql", flush=True)
    tools = {name: shutil.which(name) for name in ("initdb", "pg_ctl", "psql")}
    if not all(tools.values()):
        raise SystemExit("SKIPPED: local PostgreSQL initdb/pg_ctl/psql not available")
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    with tempfile.TemporaryDirectory(prefix="nuhani-backend-") as temp:
        root = Path(temp)
        data, sock = root / "data", root / "socket"
        sock.mkdir()
        started = False
        def run(command, **kwargs):
            return subprocess.run(command, env=env, cwd=root, text=True, **kwargs)
        def sql(path, expect_fail=False, expected_error=None):
            transaction = ["--single-transaction"] if path.name in NEW else []
            result = run([tools["psql"], *transaction, "-X", "-h", str(sock), "-p", "55439", "-U", "postgres",
                          "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-f", str(path)], capture_output=True)
            lines = [line for line in (result.stdout + result.stderr).splitlines()
                     if "PASS:" in line or "ERROR:" in line or "FAIL:" in line]
            if lines:
                print("\n".join(lines), flush=True)
            if expect_fail:
                if result.returncode == 0:
                    raise RuntimeError(f"Expected failure did not occur: {path.name}")
                if expected_error and expected_error not in result.stderr:
                    raise RuntimeError(f"Unexpected failure: {result.stderr}")
                print(f"EXPECTED FAILURE: {path.name}", flush=True)
            elif result.returncode:
                print(result.stdout + result.stderr, flush=True)
                raise RuntimeError(f"SQL failed: {path.name}")
        def sql_text(name, text):
            path = root / name
            path.write_text(text)
            sql(path)
        try:
            run([tools["initdb"], "-D", str(data), "-U", "postgres", "-A", "trust", "--no-locale", "--encoding=UTF8"],
                check=True, capture_output=True)
            # No TCP listener, and our unique private Unix socket cannot resolve to an existing server.
            run([tools["pg_ctl"], "-D", str(data), "-l", str(root / "postgres.log"),
                 "-o", f"-k {sock} -p 55439 -c listen_addresses='' -c fsync=off", "-w", "start"],
                check=True, capture_output=True)
            started = True
            print("SETUP: fresh PostgreSQL cluster; TCP disabled; credentials empty; outbound HTTP stubbed", flush=True)
            sql(TESTS / "local_bootstrap.sql")
            for path in sorted(MIGRATIONS.glob("*.sql")):
                if path.name in NEW:
                    continue
                text = path.read_text()
                # The stock PostgreSQL installation has no pg_net. Keep every historical
                # function/trigger definition, replacing only extension install with offline shim.
                text = text.replace("CREATE EXTENSION IF NOT EXISTS pg_net;", "-- Offline net.http_post shim already installed.")
                copy = root / path.name
                copy.write_text(text)
                sql(copy)
            if args.red:
                sql(TESTS / "profile_roles.sql", expect_fail=True)
                sql(TESTS / "shipping_settings.sql", expect_fail=True)
                sql(TESTS / "order_quotes.sql", expect_fail=True, expected_error="get_order_quote")
                print("RED: missing security/shipping/authoritative-quote behaviors observed", flush=True)
                return
            sql(TESTS / "historical_fixture.sql")
            for name in NEW:
                sql(MIGRATIONS / name)
            sql(TESTS / "migration_preservation.sql")
            sql(TESTS / "apply_twice.sql")
            for name in ("telegram_denial.sql", "profile_roles.sql", "shipping_settings.sql", "order_total_guard.sql", "order_quotes.sql", "quote_readonly.sql"):
                sql(TESTS / name)
            # Explicit forward/down/forward test, plus failed preflight atomicity.
            sql(TESTS / "migration_roundtrip.sql")
            sql_text("duplicate_settings.sql", "INSERT INTO public.site_settings DEFAULT VALUES;")
            sql(MIGRATIONS / NEW[1], expect_fail=True, expected_error="Shipping settings are ambiguous")
            sql_text("duplicate_unchanged.sql", """
DO $$ BEGIN
  IF (SELECT count(*) FROM public.site_settings) <> 2 OR EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
    AND table_name = 'site_settings' AND column_name = 'shipping_default_rate') THEN
    RAISE EXCEPTION 'FAIL: duplicate preflight changed rows/schema';
  END IF;
  RAISE NOTICE 'PASS: duplicate preflight aborts without changing rows/schema';
END $$;
DELETE FROM public.site_settings;
""")
            sql(MIGRATIONS / NEW[1], expect_fail=True, expected_error="Shipping settings are missing")
            sql_text("missing_unchanged.sql", """
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.site_settings) OR EXISTS (
    SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
    AND table_name = 'site_settings' AND column_name = 'shipping_default_rate') THEN
    RAISE EXCEPTION 'FAIL: missing preflight changed rows/schema';
  END IF;
  RAISE NOTICE 'PASS: missing preflight aborts without seeding or changing schema';
END $$;
INSERT INTO public.site_settings SELECT * FROM backend_test.original_settings;
""")
            sql(TESTS / "caller_transaction.sql")
            for name in NEW:
                sql(MIGRATIONS / name)
            sql(TESTS / "migration_preservation.sql")
            sql(TESTS / "quote_readonly.sql")
            print("GREEN: backend SQL suites, down/up roundtrip, and failed-preflight checks passed", flush=True)
        finally:
            if started:
                run([tools["pg_ctl"], "-D", str(data), "-m", "immediate", "-w", "stop"], check=True, capture_output=True)
            print("CLEANUP: private PostgreSQL cluster stopped and temporary data removed", flush=True)

if __name__ == "__main__":
    main()
