from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import signal
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path
from typing import Any


IRIS_MYSQL_USER_KEY = "IRIS_MYSQL_USER"
IRIS_MYSQL_PASSWORD_KEY = "IRIS_MYSQL_PASSWORD"  # pragma: allowlist secret
LOCAL_MACHINE_PROVIDER = "windows-dpapi-local-machine"
MAX_STORE_BYTES = 1_048_576
MAX_SETTINGS_BYTES = 65_536
STOP_TIMEOUT_SECONDS = 30


class LegacyGunBoundLaunchError(RuntimeError):
    pass


class DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def decrypt_local_machine_dpapi(value: str) -> str:
    if os.name != "nt":
        raise LegacyGunBoundLaunchError("The scoped Iris SQL Vault requires Windows DPAPI")
    try:
        encrypted = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        raise LegacyGunBoundLaunchError("The scoped Iris SQL Vault contains invalid DPAPI data") from exc
    input_buffer = ctypes.create_string_buffer(encrypted)
    input_blob = DataBlob(len(encrypted), ctypes.cast(input_buffer, ctypes.POINTER(ctypes.c_char)))
    output_blob = DataBlob()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(input_blob), None, None, None, None, 0x01, ctypes.byref(output_blob)
    ):
        raise LegacyGunBoundLaunchError("The scoped Iris SQL credential could not be decrypted")
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(output_blob.pbData)


def load_iris_database_credentials(path: Path) -> dict[str, str]:
    try:
        if path.stat().st_size > MAX_STORE_BYTES:
            raise LegacyGunBoundLaunchError("The scoped Iris SQL Vault exceeds its safety limit")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except LegacyGunBoundLaunchError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LegacyGunBoundLaunchError("The scoped Iris SQL Vault is unavailable or malformed") from exc
    encrypted = payload.get("credentials") if isinstance(payload, dict) else None
    expected = {IRIS_MYSQL_USER_KEY, IRIS_MYSQL_PASSWORD_KEY}
    if (
        not isinstance(payload, dict)
        or payload.get("version") != 1
        or payload.get("provider") != LOCAL_MACHINE_PROVIDER
        or not isinstance(encrypted, dict)
        or set(encrypted) != expected
    ):
        raise LegacyGunBoundLaunchError("The scoped Vault must contain only the machine-protected Iris SQL identity")
    credentials = {
        "username": decrypt_local_machine_dpapi(str(encrypted[IRIS_MYSQL_USER_KEY])),
        "password": decrypt_local_machine_dpapi(str(encrypted[IRIS_MYSQL_PASSWORD_KEY])),
    }
    if not credentials["username"] or not credentials["password"]:
        raise LegacyGunBoundLaunchError("The scoped Iris SQL identity is incomplete")
    return credentials


def load_properties(path: Path) -> dict[str, str]:
    try:
        if path.stat().st_size > MAX_SETTINGS_BYTES:
            raise LegacyGunBoundLaunchError("The WC2 settings file exceeds its safety limit")
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError as exc:
        raise LegacyGunBoundLaunchError("The WC2 settings file is unavailable") from exc
    values: dict[str, str] = {}
    for line in lines:
        item = line.strip()
        if not item or item.startswith("#") or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key:
            values[key] = value.strip()
    return values


def required_int(values: dict[str, str], key: str, minimum: int = 0, maximum: int = 2_147_483_647) -> int:
    try:
        value = int(values[key])
    except (KeyError, TypeError, ValueError) as exc:
        raise LegacyGunBoundLaunchError(f"The WC2 setting {key} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise LegacyGunBoundLaunchError(f"The WC2 setting {key} is outside its allowed range")
    return value


def required_text(values: dict[str, str], key: str, maximum: int = 128) -> str:
    value = str(values.get(key) or "").strip()
    if not value or len(value) > maximum or any(character in value for character in "\r\n\x00"):
        raise LegacyGunBoundLaunchError(f"The WC2 setting {key} is invalid")
    return value


def load_json_template(config_path: Path) -> dict[str, Any]:
    template_path = config_path.with_name(f"{config_path.stem}.iris-template.json")
    if not template_path.exists():
        try:
            template = json.loads(config_path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise LegacyGunBoundLaunchError(f"The required WC2 configuration is unavailable: {config_path}") from exc
        if not isinstance(template, dict):
            raise LegacyGunBoundLaunchError(f"The required WC2 configuration is invalid: {config_path}")
        template.pop("Mysql", None)
        write_json_atomic(template_path, template)
    try:
        template = json.loads(template_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LegacyGunBoundLaunchError(f"The protected WC2 configuration template is unavailable: {template_path}") from exc
    if not isinstance(template, dict):
        raise LegacyGunBoundLaunchError(f"The protected WC2 configuration template is invalid: {template_path}")
    return template


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".iris-tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def mysql_projection(credentials: dict[str, str], host: str, port: int, database: str, names: tuple[str, ...]) -> dict[str, Any]:
    projection: dict[str, Any] = {"SslMode": "None"}
    for name in names:
        projection.update(
            {
                f"{name}_Host": host,
                f"{name}_Port": port,
                f"{name}_User": credentials["username"],
                f"{name}_Pwd": credentials["password"],
                f"{name}_DB": database,
            }
        )
    return projection


def project_runtime_configs(
    server_root: Path, credentials: dict[str, str], database_host: str, database_port: int, database_name: str
) -> tuple[int, int]:
    settings = load_properties(server_root / "iris-legacy-settings.properties")
    broker_port = required_int(settings, "broker.port", 1, 65535)
    game_port = required_int(settings, "game.port", 1, 65535)
    broker = load_json_template(server_root / "BrokerServer" / "Config.json")
    game = load_json_template(server_root / "GameServer" / "Config" / "Config.json")
    broker["Mysql"] = mysql_projection(credentials, database_host, database_port, database_name, ("GunBoundDB", "AdminDB"))
    broker["Port"] = broker_port
    broker["LogPackets"] = settings.get("diagnostics.log_packets", "false").casefold() == "true"
    broker["Servers"] = [
        {
            "Name": required_text(settings, "broker.world.name", 64),
            "Ip": required_text(settings, "broker.world.address", 253),
            "Port": game_port,
            "MaxConnection": required_int(settings, "broker.world.capacity", 1, 5000),
        }
    ]
    game["Mysql"] = mysql_projection(
        credentials,
        database_host,
        database_port,
        database_name,
        ("GunBoundDB", "AdminDB", "ItemDB", "RecordDB", "GuildDB"),
    )
    game["Port"] = game_port
    numeric_map = {
        "GolfFactor": "game.golf.factor",
        "ScoreFactor": "game.score.factor",
        "GradeLimitFirst": "game.grade.first",
        "GradeLimitLast": "game.grade.last",
        "FuncRestrict": "game.function.restriction",
        "MaxConnection": "game.max.connection",
        "ItemSeal": "game.item.seal",
        "ItemEnchantLv1_4": "game.item.enchant.1_4",
        "ItemEnchantLv5_8": "game.item.enchant.5_8",
        "ItemEnchantLv9_12": "game.item.enchant.9_12",
        "ItemEnchantLv13_16": "game.item.enchant.13_16",
        "ItemEnchantLv17_18": "game.item.enchant.17_18",
        "ItemEnchantLv19_20": "game.item.enchant.19_20",
        "ItemEnchantLv21_30": "game.item.enchant.21_30",
        "VersionFirst": "client.version.first",
        "CheckSum": "client.checksum",
        "EventActProp0": "event.actprop.0",
        "EventActProp1": "event.actprop.1",
        "EventActProp2": "event.actprop.2",
        "EventActProp3": "event.actprop.3",
    }
    for config_key, setting_key in numeric_map.items():
        game[config_key] = required_int(settings, setting_key)
    game["EnableItem2"] = settings.get("game.enable_item2", "false").casefold() == "true"
    game["LogPackets"] = settings.get("diagnostics.log_packets", "false").casefold() == "true"
    write_json_atomic(server_root / "BrokerServer" / "Config.json", broker)
    write_json_atomic(server_root / "GameServer" / "Config" / "Config.json", game)
    return broker_port, game_port


def start_pair(server_root: Path) -> tuple[subprocess.Popen[bytes], subprocess.Popen[bytes]]:
    broker = subprocess.Popen([str(server_root / "BrokerServer" / "BrokerServer.exe")], cwd=server_root / "BrokerServer")
    time.sleep(0.75)
    if broker.poll() is not None:
        raise LegacyGunBoundLaunchError(f"BrokerServer exited during startup ({broker.returncode})")
    game = subprocess.Popen([str(server_root / "GameServer" / "GameServer.exe")], cwd=server_root / "GameServer")
    return broker, game


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=STOP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=STOP_TIMEOUT_SECONDS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Launch the legacy WC2 v894 GunBound service pair with Iris SQL credentials.")
    parser.add_argument("--server-root", type=Path, default=Path(r"D:\Gunbound"))
    parser.add_argument("--credential-store", type=Path, required=True)
    parser.add_argument("--database-host", default="127.0.0.1")
    parser.add_argument("--database-port", type=int, default=3306)
    parser.add_argument("--database-name", default="gunbound")
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    server_root = args.server_root.resolve()
    if not (1 <= args.database_port <= 65535) or not args.database_host.strip() or not args.database_name.strip():
        raise LegacyGunBoundLaunchError("The database endpoint is invalid")
    required = [
        server_root / "BrokerServer" / "BrokerServer.exe",
        server_root / "GameServer" / "GameServer.exe",
        server_root / "iris-legacy-settings.properties",
        args.credential_store.resolve(),
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise LegacyGunBoundLaunchError(f"Required WC2 runtime files are unavailable: {missing}")
    credentials = load_iris_database_credentials(args.credential_store.resolve())
    broker_port, game_port = project_runtime_configs(
        server_root, credentials, args.database_host.strip(), args.database_port, args.database_name.strip()
    )
    if args.check:
        print(json.dumps({"ok": True, "broker_port": broker_port, "game_port": game_port, "password_disclosed": False}))
        return 0
    processes: tuple[subprocess.Popen[bytes], subprocess.Popen[bytes]] | None = None
    stopping = False

    def handle_stop(_signum: int, _frame: Any) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)
    try:
        processes = start_pair(server_root)
        print(f"[legacy-launcher] STARTED broker_pid={processes[0].pid} game_pid={processes[1].pid}", flush=True)
        while not stopping:
            broker_code = processes[0].poll()
            game_code = processes[1].poll()
            if broker_code is not None or game_code is not None:
                return int(broker_code if broker_code is not None else game_code or 1)
            time.sleep(0.5)
        return 0
    finally:
        if processes:
            for process in reversed(processes):
                try:
                    stop_process(process)
                except Exception:
                    pass
        credentials["password"] = ""


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LegacyGunBoundLaunchError as exc:
        print(f"GunBound WC2 launch failed: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
