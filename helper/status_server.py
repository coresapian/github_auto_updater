#!/usr/bin/env python3
import ast
import ipaddress
import json
import os
import re
import subprocess
import sys
import threading
import time
from copy import deepcopy
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

HOME = Path.home()
SCRIPT_PATH = HOME / ".local/bin/github-auto-update.sh"
MAIN_LOG = HOME / ".local/var/log/github-auto-update.log"
ALERT_LOG = HOME / ".local/var/log/github-auto-update.alert.log"
REPO_LOG_DIR = HOME / ".local/var/log/github-auto-update"
GITHUB_DIR = HOME / "Documents/GitHub"
CRON_ENTRY = f"*/30 * * * * {SCRIPT_PATH}"
PORT = 8787
RUN_TOKEN_ENV = "GITHUB_AUTO_UPDATER_HELPER_TOKEN"
READ_TOKEN_ENV = "GITHUB_AUTO_UPDATER_AUTH_TOKEN"
RUN_HEADER = "X-Updater-Token"
AUTH_HEADER = "Authorization"
MAX_ACTION_HISTORY = 8
POLL_SECONDS = 1.0

RUN_STATE = {"current": None, "history": []}
RUN_LOCK = threading.Lock()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


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


def run_cmd(cmd: list[str], timeout: int = 20) -> tuple[int, str]:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=HOME,
        )
        return result.returncode, ((result.stdout or "") + (result.stderr or "")).strip()
    except Exception as exc:
        return 1, str(exc)


def get_crontab() -> str:
    rc, out = run_cmd(["crontab", "-l"], timeout=10)
    if rc != 0 and "no crontab" not in out.lower():
        return out or "Unable to read crontab"
    return out


def list_backups() -> list[str]:
    if not GITHUB_DIR.exists():
        return []
    paths = []
    for item in GITHUB_DIR.iterdir():
        if item.is_dir() and ("backup-" in item.name or ".corrupt-backup-" in item.name):
            paths.append(str(item))
    return sorted(paths, key=str.lower)


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


def get_run_state_snapshot() -> dict:
    with RUN_LOCK:
        current = clone_action(RUN_STATE["current"])
        history = [clone_action(item) for item in RUN_STATE["history"]]
    latest = current or (history[0] if history else None)
    return {
        "current": current,
        "latest": latest,
        "history": history,
        "tokenConfigured": bool(os.environ.get(RUN_TOKEN_ENV, "").strip() or os.environ.get(READ_TOKEN_ENV, "").strip()),
        "postEndpoint": "/run-updater",
        "authHeader": RUN_HEADER,
    }


def record_action(action: dict):
    with RUN_LOCK:
        RUN_STATE["history"] = [clone_action(action)] + [item for item in RUN_STATE["history"] if item.get("id") != action.get("id")]
        RUN_STATE["history"] = RUN_STATE["history"][:MAX_ACTION_HISTORY]
        if RUN_STATE["current"] and RUN_STATE["current"].get("id") == action.get("id"):
            RUN_STATE["current"] = clone_action(action)


def update_current_action(mutator):
    with RUN_LOCK:
        current = RUN_STATE["current"]
        if not current:
            return None
        mutator(current)
        snapshot = clone_action(current)
        RUN_STATE["history"] = [snapshot] + [item for item in RUN_STATE["history"] if item.get("id") != snapshot.get("id")]
        RUN_STATE["history"] = RUN_STATE["history"][:MAX_ACTION_HISTORY]
        return snapshot


def finalize_current_action(action_id: str, finished_action: dict):
    with RUN_LOCK:
        current = RUN_STATE["current"]
        if current and current.get("id") == action_id:
            RUN_STATE["current"] = None
        RUN_STATE["history"] = [clone_action(finished_action)] + [item for item in RUN_STATE["history"] if item.get("id") != action_id]
        RUN_STATE["history"] = RUN_STATE["history"][:MAX_ACTION_HISTORY]


def build_runner_env() -> dict:
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + env.get("PATH", "")
    return env


def run_updater_in_background(action: dict, repo_targets: list[dict], baseline: dict[str, dict]):
    action_id = action["id"]
    started_epoch = time.time()

    def runner():
        proc = None
        try:
            def mark_started(current: dict):
                current["state"] = "running"
                current["startedAt"] = utc_now_iso()
                current["statusMessage"] = "Updater script is running."
                current["progress"] = compute_progress(repo_targets, baseline, started_epoch)

            update_current_action(mark_started)
            proc = subprocess.Popen(
                [sys.executable, str(SCRIPT_PATH)],
                cwd=str(HOME),
                env=build_runner_env(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

            while proc.poll() is None:
                progress = compute_progress(repo_targets, baseline, started_epoch)

                def mark_progress(current: dict):
                    current["pid"] = proc.pid
                    current["progress"] = progress
                    if progress.get("lastTouchedRepo"):
                        current["statusMessage"] = f"Updater script running. Last completed repo: {progress['lastTouchedRepo']}"

                update_current_action(mark_progress)
                time.sleep(POLL_SECONDS)

            exit_code = proc.wait(timeout=1)
            summary = latest_main_summary()
            progress = compute_progress(repo_targets, baseline, started_epoch)
            finished = clone_action(get_run_state_snapshot()["current"] or action) or action
            finished["state"] = "succeeded" if exit_code == 0 else "failed"
            finished["finishedAt"] = utc_now_iso()
            finished["exitCode"] = exit_code
            finished["progress"] = progress
            finished["latestSummary"] = summary
            finished["statusMessage"] = summary.get("summary") or ("Updater completed successfully." if exit_code == 0 else "Updater failed.")
            finalize_current_action(action_id, finished)
        except Exception as exc:
            failed = clone_action(get_run_state_snapshot()["current"] or action) or action
            failed["state"] = "failed"
            failed["finishedAt"] = utc_now_iso()
            failed["statusMessage"] = f"Failed to launch updater: {exc}"
            failed["latestSummary"] = latest_main_summary()
            finalize_current_action(action_id, failed)
            if proc and proc.poll() is None:
                proc.kill()

    thread = threading.Thread(target=runner, name=f"manual-updater-{action_id}", daemon=True)
    thread.start()


def status_payload() -> dict:
    crontab = get_crontab()
    repos = [latest_repo_status(path) for path in repo_logs()]
    backups = list_backups()
    return {
        "cronInstalled": CRON_ENTRY in crontab,
        "cronEntry": CRON_ENTRY,
        "scriptPath": str(SCRIPT_PATH),
        "mainLog": str(MAIN_LOG),
        "alertLog": str(ALERT_LOG),
        "repoLogDir": str(REPO_LOG_DIR),
        "backups": backups,
        "repos": repos,
        "crontab": crontab,
        "latestSummary": latest_main_summary(),
        "manualRun": get_run_state_snapshot(),
        "helperTime": utc_now_iso(),
        "dashboard": build_dashboard_summary(repos, backups),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "GitHubAutoUpdaterHelper/0.3"

    def _send(self, payload: dict, status: int = 200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", f"Content-Type, {RUN_HEADER}, {AUTH_HEADER}")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else ""

    def _is_private_or_loopback(self) -> bool:
        try:
            ip = ipaddress.ip_address(self._client_ip())
            return ip.is_private or ip.is_loopback
        except ValueError:
            return False

    def _read_json_body(self) -> dict:
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0
        if content_length <= 0:
            return {}
        raw = self.rfile.read(min(content_length, 8192))
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
            return data if isinstance(data, dict) else {}
        except json.JSONDecodeError:
            raise ValueError("Request body must be valid JSON.")

    def _extract_token(self, body: dict | None = None) -> str:
        body = body or {}
        auth = self.headers.get(AUTH_HEADER, "")
        if auth.lower().startswith("bearer "):
            return auth.split(" ", 1)[1].strip()
        return (self.headers.get(RUN_HEADER, "") or body.get("token", "") or "").strip()

    def _authorize_read(self, body: dict | None = None) -> tuple[bool, str]:
        configured = os.environ.get(READ_TOKEN_ENV, "").strip()
        if not configured:
            return True, ""
        supplied = self._extract_token(body)
        if supplied != configured:
            return False, f"Missing or invalid bearer token for {READ_TOKEN_ENV}."
        return True, ""

    def _authorize_manual_post(self, body: dict) -> tuple[bool, str]:
        allowed, message = self._authorize_read(body)
        if not allowed:
            return allowed, message
        if not self._is_private_or_loopback():
            return False, "Manual updater POST is only allowed from loopback or private-network clients."
        configured_token = os.environ.get(RUN_TOKEN_ENV, "").strip()
        supplied_token = self._extract_token(body)
        if configured_token and supplied_token != configured_token:
            return False, f"Missing or invalid {RUN_HEADER}."
        try:
            if not configured_token and not ipaddress.ip_address(self._client_ip()).is_loopback:
                return False, f"Set {RUN_TOKEN_ENV} before allowing LAN-triggered manual runs."
        except ValueError:
            return False, "Unable to validate client IP."
        return True, ""

    def do_OPTIONS(self):
        self._send({"ok": True})

    def do_GET(self):
        path = self.path.rstrip("/") or "/"
        allowed, message = self._authorize_read()
        if not allowed:
            self._send({"error": message}, status=401)
            return
        if path == "/status":
            self._send(status_payload())
            return
        if path == "/log/main":
            self._send({"name": "main", "content": read_text(MAIN_LOG, 400)})
            return
        if path == "/log/alert":
            self._send({"name": "alert", "content": read_text(ALERT_LOG, 300)})
            return
        if path.startswith("/log/repo/"):
            name = unquote(path.split("/log/repo/", 1)[1])
            safe = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
            file_path = REPO_LOG_DIR / f"{safe}.log"
            self._send({"name": name, "content": read_text(file_path, 300)})
            return
        self._send({"error": "not found"}, status=404)

    def do_POST(self):
        path = self.path.rstrip("/") or "/"
        if path != "/run-updater":
            self._send({"error": "not found"}, status=404)
            return
        try:
            body = self._read_json_body()
        except ValueError as exc:
            self._send({"error": str(exc)}, status=400)
            return
        allowed, message = self._authorize_manual_post(body)
        if not allowed:
            self._send({"error": message}, status=403)
            return
        if not SCRIPT_PATH.exists():
            self._send({"error": f"Updater script not found: {SCRIPT_PATH}"}, status=500)
            return
        repo_targets = load_repo_targets()
        baseline = snapshot_repo_logs(repo_targets)
        action = {
            "id": f"manual-{int(time.time())}",
            "state": "queued",
            "requestedAt": utc_now_iso(),
            "startedAt": None,
            "finishedAt": None,
            "trigger": "manual-post",
            "clientIP": self._client_ip(),
            "pid": None,
            "exitCode": None,
            "statusMessage": "Manual updater run accepted.",
            "latestSummary": latest_main_summary(),
            "progress": {
                "totalRepos": len(repo_targets),
                "completedRepos": 0,
                "percent": 0,
                "touchedRepos": [],
                "lastTouchedRepo": None,
                "lastTouchedAt": None,
            },
        }
        with RUN_LOCK:
            if RUN_STATE["current"]:
                already_running = {
                    "error": "Updater run already in progress.",
                    "manualRun": get_run_state_snapshot(),
                }
            else:
                RUN_STATE["current"] = clone_action(action)
                RUN_STATE["history"] = [clone_action(action)] + [item for item in RUN_STATE["history"] if item.get("id") != action.get("id")]
                RUN_STATE["history"] = RUN_STATE["history"][:MAX_ACTION_HISTORY]
                already_running = None
        if already_running:
            self._send(already_running, status=409)
            return
        run_updater_in_background(action, repo_targets, baseline)
        self._send({"ok": True, "manualRun": get_run_state_snapshot()}, status=202)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Serving GitHub auto updater status on http://0.0.0.0:{PORT}")
    print(f"Manual updater endpoint: POST http://127.0.0.1:{PORT}/run-updater")
    print(f"Optional read token env var: {READ_TOKEN_ENV}")
    print(f"Optional manual-run token env var: {RUN_TOKEN_ENV}")
    server.serve_forever()
