from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import subprocess
import sys
from ctypes import wintypes
from pathlib import Path
from typing import Any


DEFAULT_SERVER_ROOT = Path(r"D:\Gunbound\Server")
DEFAULT_CREDENTIAL_STORE = DEFAULT_SERVER_ROOT / "config" / "iris-sql-vault.local.json"
DEFAULT_RUNTIME_NAME = "GunBound.Emulator.exe"
IRIS_MYSQL_USER_KEY = "IRIS_MYSQL_USER"
IRIS_MYSQL_PASSWORD_KEY = "IRIS_MYSQL_PASSWORD"  # pragma: allowlist secret
LOCAL_MACHINE_PROVIDER = "windows-dpapi-local-machine"
MAX_STORE_BYTES = 1_048_576


class GunBoundLaunchError(RuntimeError):
    pass


class DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_char)),
    ]


def decrypt_local_machine_dpapi(value: str) -> str:
    if os.name != "nt":
        raise GunBoundLaunchError("The scoped Iris SQL Vault requires Windows DPAPI")
    try:
        encrypted = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        raise GunBoundLaunchError("The scoped Iris SQL Vault contains invalid DPAPI data") from exc
    input_buffer = ctypes.create_string_buffer(encrypted)
    input_blob = DataBlob(
        len(encrypted),
        ctypes.cast(input_buffer, ctypes.POINTER(ctypes.c_char)),
    )
    output_blob = DataBlob()
    ok = ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(input_blob),
        None,
        None,
        None,
        None,
        0x01,
        ctypes.byref(output_blob),
    )
    if not ok:
        raise GunBoundLaunchError("The scoped Iris SQL credential could not be decrypted")
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(output_blob.pbData)


def load_iris_database_credentials(path: Path) -> dict[str, str]:
    try:
        if path.stat().st_size > MAX_STORE_BYTES:
            raise GunBoundLaunchError("The scoped Iris SQL Vault exceeds its safety limit")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except GunBoundLaunchError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GunBoundLaunchError("The scoped Iris SQL Vault is unavailable or malformed") from exc
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise GunBoundLaunchError("The scoped Iris SQL Vault version is unsupported")
    if payload.get("provider") != LOCAL_MACHINE_PROVIDER:
        raise GunBoundLaunchError("The scoped Iris SQL Vault must use machine-scoped DPAPI")
    encrypted = payload.get("credentials")
    expected = {IRIS_MYSQL_USER_KEY, IRIS_MYSQL_PASSWORD_KEY}
    if not isinstance(encrypted, dict) or set(encrypted) != expected:
        raise GunBoundLaunchError("The scoped Vault must contain only the Iris SQL identity")
    credentials = {
        "username": decrypt_local_machine_dpapi(str(encrypted[IRIS_MYSQL_USER_KEY])),
        "password": decrypt_local_machine_dpapi(str(encrypted[IRIS_MYSQL_PASSWORD_KEY])),
    }
    if not credentials["username"] or not credentials["password"]:
        raise GunBoundLaunchError("The scoped Iris SQL identity is incomplete")
    return credentials


def resolve_runtime(server_root: Path) -> dict[str, Path]:
    executable = server_root / "dotnet-runtime" / DEFAULT_RUNTIME_NAME
    config = server_root / "config" / "db.properties"
    missing = [str(path) for path in (executable, config) if not path.is_file()]
    if missing:
        raise GunBoundLaunchError(f"GunBound runtime files are unavailable: {missing}")
    return {"executable": executable, "config": config}


def build_environment(
    credentials: dict[str, str],
    runtime: dict[str, Path],
    *,
    database_host: str,
    database_port: int,
    database_name: str,
) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update(
        {
            "GUNBOUND_CONFIG_FILE": str(runtime["config"]),
            "GUNBOUND_DB_URL": (
                f"jdbc:mysql://{database_host}:{database_port}/{database_name}"
                "?useUnicode=true&characterEncoding=latin1&sslMode=DISABLED"
                "&allowPublicKeyRetrieval=true"
            ),
            "GUNBOUND_DB_USER": credentials["username"],
            "GUNBOUND_DB_PASSWORD": credentials["password"],
        }
    )
    return environment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Launch GunBound with the scoped, DPAPI-protected Iris SQL identity."
    )
    parser.add_argument("--server-root", type=Path, default=DEFAULT_SERVER_ROOT)
    parser.add_argument("--credential-store", type=Path, default=DEFAULT_CREDENTIAL_STORE)
    parser.add_argument("--database-host", default="127.0.0.1")
    parser.add_argument("--database-port", type=int, default=3306)
    parser.add_argument("--database-name", default="gunbound")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server_root = args.server_root.resolve()
    credential_store = args.credential_store.resolve()
    if not (1 <= args.database_port <= 65535):
        raise GunBoundLaunchError("The database port is invalid")
    if not args.database_host.strip() or not args.database_name.strip():
        raise GunBoundLaunchError("The database endpoint is incomplete")
    credentials = load_iris_database_credentials(credential_store)
    runtime = resolve_runtime(server_root)
    if args.check:
        print(
            json.dumps(
                {
                    "ok": True,
                    "server_root": str(server_root),
                    "runtime": str(runtime["executable"]),
                    "config": str(runtime["config"]),
                    "database": args.database_name,
                    "credential_keys": [IRIS_MYSQL_USER_KEY, IRIS_MYSQL_PASSWORD_KEY],
                    "credential_provider": LOCAL_MACHINE_PROVIDER,
                    "password_disclosed": False,
                },
                indent=2,
            )
        )
        return 0

    environment = build_environment(
        credentials,
        runtime,
        database_host=args.database_host.strip(),
        database_port=args.database_port,
        database_name=args.database_name.strip(),
    )
    command = [str(runtime["executable"]), "--server"]
    process: subprocess.Popen[str] | None = None
    try:
        process = subprocess.Popen(command, cwd=server_root, env=environment)
        return int(process.wait())
    except KeyboardInterrupt:
        if process and process.poll() is None:
            process.terminate()
            try:
                return int(process.wait(timeout=30))
            except subprocess.TimeoutExpired:
                process.kill()
                return int(process.wait())
        return 130
    finally:
        environment["GUNBOUND_DB_PASSWORD"] = ""
        credentials["password"] = ""


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GunBoundLaunchError as exc:
        print(f"GunBound launch failed: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
