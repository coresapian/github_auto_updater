#!/usr/bin/env python3
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
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
    except Exception as e:
        return 1, str(e)


def get_crontab() -> str:
    rc, out = run_cmd(["crontab", "-l"], timeout=10)
    if rc != 0 and "no crontab" not in out.lower():
        return out or "Unable to read crontab"
    return out


def list_backups() -> list[str]:
    if not GITHUB_DIR.exists():
        return []
    paths = []
    for p in GITHUB_DIR.iterdir():
        if p.is_dir() and ("backup-" in p.name or ".corrupt-backup-" in p.name):
            paths.append(str(p))
    return sorted(paths, key=str.lower)


def latest_repo_status(repo_log: Path) -> dict:
    text = read_text(repo_log, tail_lines=200)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    state = "unknown"
    summary = "No recent status"
    for line in reversed(lines):
        if line.startswith("ok: "):
            state = "ok"
            summary = line
            break
        if line.startswith("skip: "):
            summary = line
            lower = line.lower()
            if "working tree has local changes" in lower:
                state = "skipped"
            elif "not a git repository" in lower:
                state = "warning"
            else:
                state = "failed"
            break
    repo_name = repo_log.name.rsplit(".log", 1)[0]
    return {"id": repo_name, "repo": repo_name, "state": state, "summary": summary}


def repo_logs() -> list[Path]:
    if not REPO_LOG_DIR.exists():
        return []
    return sorted([p for p in REPO_LOG_DIR.iterdir() if p.is_file()], key=lambda p: p.name.lower())


def status_payload() -> dict:
    crontab = get_crontab()
    return {
        "cronInstalled": CRON_ENTRY in crontab,
        "cronEntry": CRON_ENTRY,
        "scriptPath": str(SCRIPT_PATH),
        "mainLog": str(MAIN_LOG),
        "alertLog": str(ALERT_LOG),
        "repoLogDir": str(REPO_LOG_DIR),
        "backups": list_backups(),
        "repos": [latest_repo_status(p) for p in repo_logs()],
        "crontab": crontab,
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, payload: dict, status: int = 200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.rstrip("/") or "/"
        if path == "/status":
            self._send(status_payload())
            return
        if path == "/log/main":
            self._send({"name": "main", "content": read_text(MAIN_LOG, 300)})
            return
        if path == "/log/alert":
            self._send({"name": "alert", "content": read_text(ALERT_LOG, 200)})
            return
        if path.startswith("/log/repo/"):
            name = unquote(path.split("/log/repo/", 1)[1])
            safe = re.sub(r"[^A-Za-z0-9._-]+", "_", name)
            file_path = REPO_LOG_DIR / f"{safe}.log"
            self._send({"name": name, "content": read_text(file_path, 200)})
            return
        self._send({"error": "not found"}, status=404)

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Serving GitHub auto updater status on http://0.0.0.0:{PORT}")
    server.serve_forever()
