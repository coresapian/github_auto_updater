#!/usr/bin/env python3
import ast
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote
from urllib.request import Request, urlopen

HOME = Path.home()
SCRIPT_PATH = HOME / ".local/bin/github-auto-update.sh"
MAIN_LOG = HOME / ".local/var/log/github-auto-update.log"
ALERT_LOG = HOME / ".local/var/log/github-auto-update.alert.log"
REPO_LOG_DIR = HOME / ".local/var/log/github-auto-update"
GITHUB_DIR = HOME / "Documents/GitHub"
CONFIG_DIR = HOME / ".config/github-auto-updater"
SECURITY_STATE_PATH = CONFIG_DIR / "helper_security.json"
CRON_ENTRY = f"*/30 * * * * {SCRIPT_PATH}"
PORT = int(os.getenv("GITHUB_AUTO_UPDATER_HELPER_PORT", "8787"))
RUN_TOKEN_ENV = "GITHUB_AUTO_UPDATER_HELPER_TOKEN"
READ_TOKEN_ENV = "GITHUB_AUTO_UPDATER_AUTH_TOKEN"
RUN_HEADER = "X-Updater-Token"
AUTH_HEADER = "Authorization"
MAX_ACTION_HISTORY = 8
POLL_SECONDS = 1.0
PAIRING_TTL_HOURS = 24
MAX_ISSUED_TOKENS = 20
NTFY_TOPIC_ENV = "GITHUB_AUTO_UPDATER_NTFY_TOPIC"
WEBHOOK_URL_ENV = "GITHUB_AUTO_UPDATER_WEBHOOK_URL"
APNS_TEAM_ID_ENV = "GITHUB_AUTO_UPDATER_APNS_TEAM_ID"
APNS_KEY_ID_ENV = "GITHUB_AUTO_UPDATER_APNS_KEY_ID"
APNS_KEY_PATH_ENV = "GITHUB_AUTO_UPDATER_APNS_KEY_PATH"
APNS_TOPIC_ENV = "GITHUB_AUTO_UPDATER_APNS_TOPIC"
APNS_USE_SANDBOX_ENV = "GITHUB_AUTO_UPDATER_APNS_USE_SANDBOX"
BONJOUR_SERVICE_NAME_ENV = "GITHUB_AUTO_UPDATER_BONJOUR_NAME"
BONJOUR_SERVICE_TYPE = "_ghupdater._tcp"
BONJOUR_SERVICE_DOMAIN = "local"

RUN_STATE = {"current": None, "history": []}
RUN_LOCK = threading.Lock()
BONJOUR_PROCESS = None


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def isoformat_timestamp(ts: float | None) -> str | None:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_text(path: Path, tail_lines: int = 300) -> str:
    if not path.exists():
        return f"Missing: {path}\n"
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    return "\n".join(lines[-tail_lines:]) + ("\n" if lines else "")


def run_cmd(cmd: list[str], timeout: int = 20, input_bytes: bytes | None = None) -> tuple[int, str, bytes]:
    try:
        result = subprocess.run(
            cmd,
            input=input_bytes,
            capture_output=True,
            text=input_bytes is None,
            timeout=timeout,
            cwd=HOME,
        )
        if input_bytes is None:
            return result.returncode, ((result.stdout or "") + (result.stderr or "")).strip(), b""
        return result.returncode, (result.stderr or "").strip(), result.stdout or b""
    except Exception as exc:
        return 1, str(exc), b""


def get_crontab() -> str:
    rc, out, _ = run_cmd(["crontab", "-l"], timeout=10)
    if rc != 0 and "no crontab" not in out.lower():
        return out or "Unable to read crontab"
    return out


def list_backups() -> list[str]:
    if not GITHUB_DIR.exists():
        return []
    return sorted([
        str(item) for item in GITHUB_DIR.iterdir()
        if item.is_dir() and ("backup-" in item.name or ".corrupt-backup-" in item.name)
    ], key=str.lower)


def file_timestamp(path: Path) -> str | None:
    if not path.exists():
        return None
    try:
        return isoformat_timestamp(path.stat().st_mtime)
    except OSError:
        return None


def latest_repo_status(repo_log: Path) -> dict:
    text = read_text(repo_log, tail_lines=200)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    state = "unknown"
    summary = "No recent status"
    for line in reversed(lines):
        lower = line.lower()
        if line.startswith("ok: "):
            state = "ok"
            summary = line
            break
        if line.startswith("skip: "):
            summary = line
            if "working tree has local changes" in lower:
                state = "skipped"
            elif "not a git repository" in lower or "missing" in lower:
                state = "warning"
            else:
                state = "failed"
            break
        if "error" in lower or "failed" in lower or "fatal" in lower:
            state = "failed"
            summary = line
            break
    repo_name = repo_log.name.rsplit(".log", 1)[0]
    return {
        "id": repo_name,
        "repo": repo_name,
        "state": state,
        "summary": summary,
        "updatedAt": file_timestamp(repo_log),
        "logPath": str(repo_log),
    }


def repo_logs() -> list[Path]:
    if not REPO_LOG_DIR.exists():
        return []
    return sorted([path for path in REPO_LOG_DIR.iterdir() if path.is_file()], key=lambda path: path.name.lower())


def parse_summary_counts(line: str) -> dict | None:
    match = re.search(r"summary:\s*ok=(\d+)\s+skipped=(\d+)\s+failed=(\d+)", line)
    if not match:
        return None
    return {"ok": int(match.group(1)), "skipped": int(match.group(2)), "failed": int(match.group(3))}


def latest_main_summary() -> dict:
    text = read_text(MAIN_LOG, tail_lines=500)
    lines = text.splitlines()
    summary_line = None
    stamp = None
    for line in reversed(lines):
        if summary_line is None and line.startswith("summary:"):
            summary_line = line.strip()
            continue
        if summary_line and line.startswith("====="):
            stamp = line.strip("= ")
            break
    counts = parse_summary_counts(summary_line or "")
    return {"runStamp": stamp, "summary": summary_line, "counts": counts}


def build_dashboard_summary(repos: list[dict], backups: list[str]) -> dict:
    counts = {"ok": 0, "skipped": 0, "failed": 0, "warning": 0, "unknown": 0}
    latest_updates = []
    for repo in repos:
        counts[repo["state"]] = counts.get(repo["state"], 0) + 1
        if repo.get("updatedAt"):
            latest_updates.append(repo["updatedAt"])
    alert_log_present = ALERT_LOG.exists() and ALERT_LOG.stat().st_size > 0 if ALERT_LOG.exists() else False
    return {
        "totalRepos": len(repos),
        "healthyRepos": counts.get("ok", 0),
        "attentionRepos": counts.get("failed", 0) + counts.get("warning", 0) + counts.get("skipped", 0),
        "failedRepos": counts.get("failed", 0),
        "warningRepos": counts.get("warning", 0),
        "skippedRepos": counts.get("skipped", 0),
        "unknownRepos": counts.get("unknown", 0),
        "backupsCount": len(backups),
        "alertLogPresent": alert_log_present,
        "latestRepoUpdate": max(latest_updates) if latest_updates else None,
    }


def load_repo_targets() -> list[dict]:
    if not SCRIPT_PATH.exists():
        return []
    text = SCRIPT_PATH.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"REPOS\s*=\s*(\[[\s\S]*?\])\nTIMEOUT_SECONDS", text)
    if not match:
        return []
    try:
        repos = ast.literal_eval(match.group(1))
    except Exception:
        return []
    targets = []
    for repo in repos:
        slug = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(repo).name)
        targets.append({"repo": repo, "slug": slug, "logPath": str(REPO_LOG_DIR / f"{slug}.log")})
    return targets


def snapshot_repo_logs(repo_targets: list[dict]) -> dict[str, dict]:
    snapshot = {}
    for target in repo_targets:
        path = Path(target["logPath"])
        if path.exists():
            stat = path.stat()
            snapshot[target["slug"]] = {"size": stat.st_size, "mtime": stat.st_mtime}
        else:
            snapshot[target["slug"]] = {"size": 0, "mtime": 0.0}
    return snapshot


def compute_progress(repo_targets: list[dict], baseline: dict[str, dict], started_at_epoch: float) -> dict:
    touched = []
    last_touched_repo = None
    last_touched_at = None
    for target in repo_targets:
        slug = target["slug"]
        path = Path(target["logPath"])
        current_size = 0
        current_mtime = 0.0
        if path.exists():
            stat = path.stat()
            current_size = stat.st_size
            current_mtime = stat.st_mtime
        previous = baseline.get(slug, {"size": 0, "mtime": 0.0})
        if current_size > previous["size"] and current_mtime >= started_at_epoch - 2:
            touched.append(target["repo"])
            if last_touched_at is None or current_mtime >= last_touched_at:
                last_touched_at = current_mtime
                last_touched_repo = target["repo"]
    total = len(repo_targets)
    completed = len(touched)
    percent = int(round((completed / total) * 100)) if total > 0 else 0
    return {
        "totalRepos": total,
        "completedRepos": completed,
        "percent": percent,
        "touchedRepos": touched,
        "lastTouchedRepo": last_touched_repo,
        "lastTouchedAt": isoformat_timestamp(last_touched_at),
    }


def clone_action(action: dict | None) -> dict | None:
    return deepcopy(action) if action else None


def load_security_state() -> dict:
    state = {
        "helper_instance_id": secrets.token_hex(8),
        "pairing_code_hash": "",
        "pairing_code_salt": "",
        "pairing_code_label": "",
        "pairing_code_created_at": None,
        "pairing_code_expires_at": None,
        "issued_tokens": [],
        "registered_devices": [],
        "last_notification_sent_at": None,
        "last_notification_result": None,
        "last_notification_run_stamp": None,
    }
    if SECURITY_STATE_PATH.exists():
        try:
            loaded = json.loads(SECURITY_STATE_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                state.update(loaded)
        except json.JSONDecodeError:
            pass
    return state


def save_security_state(state: dict):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    SECURITY_STATE_PATH.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    os.chmod(SECURITY_STATE_PATH, 0o600)


def make_secret_record(secret: str) -> tuple[str, str]:
    salt = secrets.token_hex(16)
    digest = hashlib.sha256(f"{salt}:{secret}".encode("utf-8")).hexdigest()
    return salt, digest


def verify_secret(secret: str, salt: str, expected_digest: str) -> bool:
    if not secret or not salt or not expected_digest:
        return False
    digest = hashlib.sha256(f"{salt}:{secret}".encode("utf-8")).hexdigest()
    return hmac.compare_digest(digest, expected_digest)


def mask_pairing_code(code: str) -> str:
    if len(code) <= 2:
        return "*" * len(code)
    return f"{'*' * (len(code) - 2)}{code[-2:]}"


def generate_pairing_code() -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(8))


def current_pairing_record(state: dict) -> dict | None:
    expires_at = parse_iso(state.get("pairing_code_expires_at"))
    if not expires_at or expires_at <= utc_now():
        return None
    if not state.get("pairing_code_hash") or not state.get("pairing_code_salt"):
        return None
    return {
        "pairingCodeLabel": state.get("pairing_code_label") or "configured",
        "pairingCodeExpiresAt": state.get("pairing_code_expires_at"),
        "pairingCodeCreatedAt": state.get("pairing_code_created_at"),
    }


def ensure_pairing_code(state: dict) -> dict:
    if current_pairing_record(state):
        return state
    code = os.getenv("GITHUB_AUTO_UPDATER_PAIRING_CODE", "").strip() or generate_pairing_code()
    salt, digest = make_secret_record(code)
    now = utc_now()
    expires = now + timedelta(hours=PAIRING_TTL_HOURS)
    state["pairing_code_salt"] = salt
    state["pairing_code_hash"] = digest
    state["pairing_code_label"] = mask_pairing_code(code)
    state["pairing_code_created_at"] = now.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    state["pairing_code_expires_at"] = expires.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    save_security_state(state)
    print(f"[pairing] Helper pairing code: {code}")
    print(f"[pairing] Expires at: {state['pairing_code_expires_at']}")
    return state


def issue_token(state: dict, device_name: str) -> dict:
    raw_token = base64.urlsafe_b64encode(secrets.token_bytes(24)).decode("utf-8").rstrip("=")
    salt, digest = make_secret_record(raw_token)
    token_id = secrets.token_hex(6)
    issued_at = utc_now_iso()
    record = {
        "id": token_id,
        "device_name": device_name,
        "salt": salt,
        "token_hash": digest,
        "token_prefix": raw_token[:6],
        "issued_at": issued_at,
        "last_used_at": None,
    }
    tokens = state.get("issued_tokens", [])
    tokens.append(record)
    state["issued_tokens"] = tokens[-MAX_ISSUED_TOKENS:]
    save_security_state(state)
    return {
        "authToken": raw_token,
        "tokenId": token_id,
        "tokenPreview": f"{raw_token[:6]}…",
        "issuedAt": issued_at,
        "deviceName": device_name,
        "helperInstanceID": state.get("helper_instance_id", ""),
        "authMode": "bearer-token",
        "pairingCodeExpiresAt": state.get("pairing_code_expires_at"),
    }


def authenticate_token(state: dict, presented_token: str) -> dict | None:
    if not presented_token:
        return None
    env_token = os.getenv(READ_TOKEN_ENV, "").strip()
    if env_token and hmac.compare_digest(presented_token, env_token):
        return {"id": "env", "device_name": "environment", "issued_at": None}
    run_token = os.getenv(RUN_TOKEN_ENV, "").strip()
    if run_token and hmac.compare_digest(presented_token, run_token):
        return {"id": "run-env", "device_name": "run-environment", "issued_at": None}
    for token in state.get("issued_tokens", []):
        if verify_secret(presented_token, token.get("salt", ""), token.get("token_hash", "")):
            token["last_used_at"] = utc_now_iso()
            save_security_state(state)
            return token
    return None


def pairing_status_payload(state: dict) -> dict:
    pairing = current_pairing_record(state)
    return {
        "authRequired": True,
        "authMode": "bearer-token",
        "helperInstanceID": state.get("helper_instance_id", ""),
        "pairingAvailable": pairing is not None,
        "pairingCodeLabel": pairing.get("pairingCodeLabel") if pairing else None,
        "pairingCodeExpiresAt": pairing.get("pairingCodeExpiresAt") if pairing else None,
        "pairingInstructions": f"On your Mac, start the helper and use the current pairing code. You can also discover the helper over Bonjour service type {BONJOUR_SERVICE_TYPE}.",
        "activeTokenCount": len(state.get("issued_tokens", [])),
        "recommendedTransport": "local-network-only",
    }


def notification_status_payload(state: dict) -> dict:
    channels = []
    if os.getenv(NTFY_TOPIC_ENV, '').strip():
        channels.append('ntfy')
    if os.getenv(WEBHOOK_URL_ENV, '').strip():
        channels.append('webhook')
    if apns_configured():
        channels.append('apns')
    return {
        'configured': bool(channels),
        'channels': channels,
        'lastSentAt': state.get('last_notification_sent_at'),
        'lastResult': state.get('last_notification_result'),
        'lastRunStamp': state.get('last_notification_run_stamp'),
        'registeredDeviceCount': len(state.get('registered_devices', [])),
        'apnsConfigured': apns_configured(),
    }


def apns_configured() -> bool:
    return all(os.getenv(env, '').strip() for env in [APNS_TEAM_ID_ENV, APNS_KEY_ID_ENV, APNS_KEY_PATH_ENV, APNS_TOPIC_ENV])


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode('utf-8').rstrip('=')


def _der_read_length(data: bytes, idx: int) -> tuple[int, int]:
    first = data[idx]
    idx += 1
    if first < 0x80:
        return first, idx
    count = first & 0x7F
    value = int.from_bytes(data[idx:idx+count], 'big')
    return value, idx + count


def der_to_raw_signature(der: bytes) -> bytes:
    if not der or der[0] != 0x30:
        raise ValueError('Invalid DER signature')
    _, idx = _der_read_length(der, 1)
    if der[idx] != 0x02:
        raise ValueError('Invalid DER signature')
    r_len, idx = _der_read_length(der, idx + 1)
    r = der[idx:idx+r_len]
    idx += r_len
    if der[idx] != 0x02:
        raise ValueError('Invalid DER signature')
    s_len, idx = _der_read_length(der, idx + 1)
    s = der[idx:idx+s_len]
    r = r.lstrip(b'\x00').rjust(32, b'\x00')
    s = s.lstrip(b'\x00').rjust(32, b'\x00')
    return r + s


def apns_jwt() -> str:
    team_id = os.getenv(APNS_TEAM_ID_ENV, '').strip()
    key_id = os.getenv(APNS_KEY_ID_ENV, '').strip()
    key_path = os.getenv(APNS_KEY_PATH_ENV, '').strip()
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(time.time())}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    rc, err, sig_der = run_cmd(["openssl", "dgst", "-sha256", "-sign", key_path], timeout=15, input_bytes=signing_input)
    if rc != 0:
        raise RuntimeError(err or 'openssl sign failed')
    sig = der_to_raw_signature(sig_der)
    return f"{header}.{claims}.{b64url(sig)}"


def register_device_token(state: dict, token: str, device_name: str, platform: str) -> dict:
    devices = state.get('registered_devices', [])
    existing = next((d for d in devices if d.get('token') == token), None)
    now = utc_now_iso()
    if existing:
        existing['device_name'] = device_name
        existing['platform'] = platform
        existing['updated_at'] = now
    else:
        devices.append({
            'id': secrets.token_hex(6),
            'token': token,
            'device_name': device_name,
            'platform': platform,
            'updated_at': now,
        })
    state['registered_devices'] = devices[-50:]
    save_security_state(state)
    return {'registeredDeviceCount': len(state['registered_devices'])}


def send_apns_notifications_if_needed(state: dict, title: str, body: str, summary: dict) -> list[str]:
    results = []
    if not apns_configured():
        return results
    devices = state.get('registered_devices', [])
    if not devices:
        return results
    topic = os.getenv(APNS_TOPIC_ENV, '').strip()
    host = 'api.sandbox.push.apple.com' if os.getenv(APNS_USE_SANDBOX_ENV, '1').strip() != '0' else 'api.push.apple.com'
    try:
        bearer = apns_jwt()
    except Exception as exc:
        return [f'apns-jwt-error:{exc}']
    payload = json.dumps({
        'aps': {
            'alert': {'title': title, 'body': body},
            'sound': 'default'
        },
        'summary': summary,
    })
    for device in devices:
        token = device.get('token', '').strip()
        if not token:
            continue
        cmd = [
            'curl', '--http2', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
            '-X', 'POST', f'https://{host}/3/device/{token}',
            '-H', f'authorization: bearer {bearer}',
            '-H', 'apns-push-type: alert',
            '-H', f'apns-topic: {topic}',
            '-H', 'content-type: application/json',
            '--data', payload,
        ]
        rc, out, _ = run_cmd(cmd, timeout=20)
        if rc == 0:
            results.append(f"apns:{device.get('device_name','device')}:{out}")
        else:
            results.append(f"apns-error:{device.get('device_name','device')}:{out}")
    return results


def send_failure_notifications_if_needed(state: dict, summary: dict):
    counts = summary.get('counts') or {}
    run_stamp = summary.get('runStamp') or summary.get('summary') or ''
    if not run_stamp or counts.get('failed', 0) <= 0:
        return
    if state.get('last_notification_run_stamp') == run_stamp:
        return
    title = 'GitHub Auto Updater Failure'
    body = summary.get('summary') or f"{counts.get('failed', 0)} repo(s) failed in the latest updater run."
    results = []
    topic = os.getenv(NTFY_TOPIC_ENV, '').strip()
    if topic:
        try:
            req = Request(f'https://ntfy.sh/{topic}', data=body.encode('utf-8'), headers={'Title': title})
            with urlopen(req, timeout=10) as resp:
                results.append(f'ntfy:{resp.status}')
        except Exception as exc:
            results.append(f'ntfy-error:{exc}')
    webhook = os.getenv(WEBHOOK_URL_ENV, '').strip()
    if webhook:
        try:
            payload = json.dumps({'title': title, 'body': body, 'summary': summary}).encode('utf-8')
            req = Request(webhook, data=payload, headers={'Content-Type': 'application/json'})
            with urlopen(req, timeout=10) as resp:
                results.append(f'webhook:{resp.status}')
        except Exception as exc:
            results.append(f'webhook-error:{exc}')
    results.extend(send_apns_notifications_if_needed(state, title, body, summary))
    if results:
        state['last_notification_sent_at'] = utc_now_iso()
        state['last_notification_result'] = '; '.join(results)
        state['last_notification_run_stamp'] = run_stamp
        save_security_state(state)


def get_run_state_snapshot() -> dict:
    with RUN_LOCK:
        current = clone_action(RUN_STATE['current'])
        history = [clone_action(item) for item in RUN_STATE['history']]
    latest = current or (history[0] if history else None)
    return {
        'current': current,
        'latest': latest,
        'history': history,
        'tokenConfigured': bool(os.environ.get(RUN_TOKEN_ENV, '').strip() or os.environ.get(READ_TOKEN_ENV, '').strip() or SECURITY_STATE.get('issued_tokens')),
        'postEndpoint': '/run-updater',
        'authHeader': RUN_HEADER,
    }


def update_current_action(mutator):
    with RUN_LOCK:
        current = RUN_STATE['current']
        if not current:
            return None
        mutator(current)
        snapshot = clone_action(current)
        RUN_STATE['history'] = [snapshot] + [item for item in RUN_STATE['history'] if item.get('id') != snapshot.get('id')]
        RUN_STATE['history'] = RUN_STATE['history'][:MAX_ACTION_HISTORY]
        return snapshot


def finalize_current_action(action_id: str, finished_action: dict):
    with RUN_LOCK:
        current = RUN_STATE['current']
        if current and current.get('id') == action_id:
            RUN_STATE['current'] = None
        RUN_STATE['history'] = [clone_action(finished_action)] + [item for item in RUN_STATE['history'] if item.get('id') != action_id]
        RUN_STATE['history'] = RUN_STATE['history'][:MAX_ACTION_HISTORY]


def build_runner_env() -> dict:
    env = os.environ.copy()
    env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:' + env.get('PATH', '')
    return env


def run_updater_in_background(action: dict, repo_targets: list[dict], baseline: dict[str, dict]):
    action_id = action['id']
    started_epoch = time.time()

    def runner():
        proc = None
        try:
            def mark_started(current: dict):
                current['state'] = 'running'
                current['startedAt'] = utc_now_iso()
                current['statusMessage'] = 'Updater script is running.'
                current['progress'] = compute_progress(repo_targets, baseline, started_epoch)
            update_current_action(mark_started)
            proc = subprocess.Popen([sys.executable, str(SCRIPT_PATH)], cwd=str(HOME), env=build_runner_env(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            while proc.poll() is None:
                progress = compute_progress(repo_targets, baseline, started_epoch)
                def mark_progress(current: dict):
                    current['pid'] = proc.pid
                    current['progress'] = progress
                    if progress.get('lastTouchedRepo'):
                        current['statusMessage'] = f"Updater script running. Last completed repo: {progress['lastTouchedRepo']}"
                update_current_action(mark_progress)
                time.sleep(POLL_SECONDS)
            exit_code = proc.wait(timeout=1)
            summary = latest_main_summary()
            progress = compute_progress(repo_targets, baseline, started_epoch)
            finished = clone_action(get_run_state_snapshot()['current'] or action) or action
            finished['state'] = 'succeeded' if exit_code == 0 else 'failed'
            finished['finishedAt'] = utc_now_iso()
            finished['exitCode'] = exit_code
            finished['progress'] = progress
            finished['latestSummary'] = summary
            finished['statusMessage'] = summary.get('summary') or ('Updater completed successfully.' if exit_code == 0 else 'Updater failed.')
            send_failure_notifications_if_needed(SECURITY_STATE, summary)
            finalize_current_action(action_id, finished)
        except Exception as exc:
            failed = clone_action(get_run_state_snapshot()['current'] or action) or action
            failed['state'] = 'failed'
            failed['finishedAt'] = utc_now_iso()
            failed['statusMessage'] = f'Failed to launch updater: {exc}'
            failed['latestSummary'] = latest_main_summary()
            finalize_current_action(action_id, failed)
            if proc and proc.poll() is None:
                proc.kill()

    threading.Thread(target=runner, name=f'manual-updater-{action_id}', daemon=True).start()


def status_payload() -> dict:
    crontab = get_crontab()
    repos = [latest_repo_status(path) for path in repo_logs()]
    backups = list_backups()
    return {
        'cronInstalled': CRON_ENTRY in crontab,
        'cronEntry': CRON_ENTRY,
        'scriptPath': str(SCRIPT_PATH),
        'mainLog': str(MAIN_LOG),
        'alertLog': str(ALERT_LOG),
        'repoLogDir': str(REPO_LOG_DIR),
        'backups': backups,
        'repos': repos,
        'crontab': crontab,
        'latestSummary': latest_main_summary(),
        'manualRun': get_run_state_snapshot(),
        'helperTime': utc_now_iso(),
        'dashboard': build_dashboard_summary(repos, backups),
        'pairing': pairing_status_payload(SECURITY_STATE),
        'notifications': notification_status_payload(SECURITY_STATE),
        'discovery': {
            'bonjourServiceName': os.getenv(BONJOUR_SERVICE_NAME_ENV, 'GitHub Auto Updater'),
            'bonjourServiceType': BONJOUR_SERVICE_TYPE,
            'port': PORT,
        },
    }


def start_bonjour_advertisement():
    global BONJOUR_PROCESS
    if BONJOUR_PROCESS is not None:
        return
    service_name = os.getenv(BONJOUR_SERVICE_NAME_ENV, 'GitHub Auto Updater').strip() or 'GitHub Auto Updater'
    if shutil_which('dns-sd') is None:
        print('[bonjour] dns-sd not available; skipping Bonjour advertisement')
        return
    try:
        BONJOUR_PROCESS = subprocess.Popen(['dns-sd', '-R', service_name, BONJOUR_SERVICE_TYPE, BONJOUR_SERVICE_DOMAIN, str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f'[bonjour] Advertising {service_name} via {BONJOUR_SERVICE_TYPE} on port {PORT}')
    except Exception as exc:
        print(f'[bonjour] Failed to advertise service: {exc}')
        BONJOUR_PROCESS = None


def shutil_which(cmd: str):
    for entry in os.environ.get('PATH', '').split(':'):
        candidate = Path(entry) / cmd
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


SECURITY_STATE = ensure_pairing_code(load_security_state())


class Handler(BaseHTTPRequestHandler):
    server_version = 'GitHubAutoUpdaterHelper/0.5'

    def _send(self, payload: dict, status: int = 200):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', f'Content-Type, {RUN_HEADER}, {AUTH_HEADER}')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else ''

    def _is_private_or_loopback(self) -> bool:
        try:
            ip = ipaddress.ip_address(self._client_ip())
            return ip.is_private or ip.is_loopback
        except ValueError:
            return False

    def _read_json_body(self) -> dict:
        try:
            content_length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            content_length = 0
        if content_length <= 0:
            return {}
        raw = self.rfile.read(min(content_length, 8192))
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode('utf-8'))
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError:
            raise ValueError('Request body must be valid JSON.')

    def _extract_token(self, body: dict | None = None) -> str:
        body = body or {}
        auth = self.headers.get(AUTH_HEADER, '')
        if auth.lower().startswith('bearer '):
            return auth.split(' ', 1)[1].strip()
        return (self.headers.get(RUN_HEADER, '') or body.get('token', '') or '').strip()

    def _authorize_read(self, body: dict | None = None) -> tuple[bool, str]:
        configured = os.getenv(READ_TOKEN_ENV, '').strip()
        supplied = self._extract_token(body)
        if configured:
            if supplied != configured:
                return False, f'Missing or invalid bearer token for {READ_TOKEN_ENV}.'
            return True, ''
        if SECURITY_STATE.get('issued_tokens'):
            if authenticate_token(SECURITY_STATE, supplied):
                return True, ''
            return False, 'Missing or invalid paired-device bearer token.'
        return True, ''

    def _authorize_manual_post(self, body: dict) -> tuple[bool, str]:
        allowed, message = self._authorize_read(body)
        if not allowed:
            return allowed, message
        if not self._is_private_or_loopback():
            return False, 'Manual updater POST is only allowed from loopback or private-network clients.'
        configured_token = os.getenv(RUN_TOKEN_ENV, '').strip()
        supplied_token = self._extract_token(body)
        if configured_token and supplied_token != configured_token and not authenticate_token(SECURITY_STATE, supplied_token):
            return False, f'Missing or invalid {RUN_HEADER}.'
        try:
            if not configured_token and not supplied_token and not ipaddress.ip_address(self._client_ip()).is_loopback:
                return False, f'Pair this device first or set {RUN_TOKEN_ENV} before allowing LAN-triggered manual runs.'
        except ValueError:
            return False, 'Unable to validate client IP.'
        return True, ''

    def do_OPTIONS(self):
        self._send({'ok': True})

    def do_GET(self):
        path = self.path.rstrip('/') or '/'
        if path == '/pairing/status':
            self._send(pairing_status_payload(SECURITY_STATE))
            return
        allowed, message = self._authorize_read()
        if not allowed:
            self._send({'error': message}, status=401)
            return
        if path == '/status':
            self._send(status_payload())
            return
        if path == '/log/main':
            self._send({'name': 'main', 'content': read_text(MAIN_LOG, 400)})
            return
        if path == '/log/alert':
            self._send({'name': 'alert', 'content': read_text(ALERT_LOG, 300)})
            return
        if path.startswith('/log/repo/'):
            name = unquote(path.split('/log/repo/', 1)[1])
            safe = re.sub(r'[^A-Za-z0-9._-]+', '_', name)
            file_path = REPO_LOG_DIR / f'{safe}.log'
            self._send({'name': name, 'content': read_text(file_path, 300)})
            return
        self._send({'error': 'not found'}, status=404)

    def do_POST(self):
        path = self.path.rstrip('/') or '/'
        try:
            body = self._read_json_body()
        except ValueError as exc:
            self._send({'error': str(exc)}, status=400)
            return

        if path == '/pairing/exchange':
            code = str(body.get('pairingCode', '')).strip().upper()
            device_name = str(body.get('deviceName', '')).strip() or 'iPhone'
            current = current_pairing_record(SECURITY_STATE)
            if not current:
                self._send({'error': 'No active pairing code is available. Restart the helper to generate a new code.'}, status=409)
                return
            if not verify_secret(code, SECURITY_STATE.get('pairing_code_salt', ''), SECURITY_STATE.get('pairing_code_hash', '')):
                self._send({'error': 'Invalid pairing code.'}, status=403)
                return
            self._send(issue_token(SECURITY_STATE, device_name), status=201)
            return

        if path == '/devices/register':
            allowed, message = self._authorize_read(body)
            if not allowed:
                self._send({'error': message}, status=401)
                return
            device_token = str(body.get('deviceToken', '')).strip()
            device_name = str(body.get('deviceName', '')).strip() or 'iPhone'
            platform = str(body.get('platform', 'ios')).strip() or 'ios'
            if not device_token:
                self._send({'error': 'Missing deviceToken.'}, status=400)
                return
            self._send({'ok': True, **register_device_token(SECURITY_STATE, device_token, device_name, platform)}, status=201)
            return

        if path != '/run-updater':
            self._send({'error': 'not found'}, status=404)
            return
        allowed, message = self._authorize_manual_post(body)
        if not allowed:
            self._send({'error': message}, status=403)
            return
        if not SCRIPT_PATH.exists():
            self._send({'error': f'Updater script not found: {SCRIPT_PATH}'}, status=500)
            return
        repo_targets = load_repo_targets()
        baseline = snapshot_repo_logs(repo_targets)
        action = {
            'id': f'manual-{int(time.time())}',
            'state': 'queued',
            'requestedAt': utc_now_iso(),
            'startedAt': None,
            'finishedAt': None,
            'trigger': 'manual-post',
            'clientIP': self._client_ip(),
            'pid': None,
            'exitCode': None,
            'statusMessage': 'Manual updater run accepted.',
            'latestSummary': latest_main_summary(),
            'progress': {
                'totalRepos': len(repo_targets),
                'completedRepos': 0,
                'percent': 0,
                'touchedRepos': [],
                'lastTouchedRepo': None,
                'lastTouchedAt': None,
            },
        }
        with RUN_LOCK:
            if RUN_STATE['current']:
                already_running = {'error': 'Updater run already in progress.', 'manualRun': get_run_state_snapshot()}
            else:
                RUN_STATE['current'] = clone_action(action)
                RUN_STATE['history'] = [clone_action(action)] + [item for item in RUN_STATE['history'] if item.get('id') != action.get('id')]
                RUN_STATE['history'] = RUN_STATE['history'][:MAX_ACTION_HISTORY]
                already_running = None
        if already_running:
            self._send(already_running, status=409)
            return
        run_updater_in_background(action, repo_targets, baseline)
        self._send({'ok': True, 'manualRun': get_run_state_snapshot()}, status=202)

    def log_message(self, format, *args):
        return


if __name__ == '__main__':
    start_bonjour_advertisement()
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'Serving GitHub auto updater status on http://0.0.0.0:{PORT}')
    print(f'Bonjour service: {os.getenv(BONJOUR_SERVICE_NAME_ENV, "GitHub Auto Updater")} {BONJOUR_SERVICE_TYPE}.{BONJOUR_SERVICE_DOMAIN}:{PORT}')
    print(f'Pairing status endpoint: GET http://127.0.0.1:{PORT}/pairing/status')
    print(f'Pairing exchange endpoint: POST http://127.0.0.1:{PORT}/pairing/exchange')
    print(f'Device registration endpoint: POST http://127.0.0.1:{PORT}/devices/register')
    print(f'Manual updater endpoint: POST http://127.0.0.1:{PORT}/run-updater')
    print(f'Optional read token env var: {READ_TOKEN_ENV}')
    print(f'Optional manual-run token env var: {RUN_TOKEN_ENV}')
    print(f'Optional ntfy topic env var: {NTFY_TOPIC_ENV}')
    print(f'Optional webhook env var: {WEBHOOK_URL_ENV}')
    print(f'Optional APNs env vars: {APNS_TEAM_ID_ENV}, {APNS_KEY_ID_ENV}, {APNS_KEY_PATH_ENV}, {APNS_TOPIC_ENV}')
    server.serve_forever()
