#!/usr/bin/env python3
"""Black-box dogfood runner for ai-max.

The runner knows only the public JSON-RPC socket. It creates real agent
threads with `execute*`, observes them through Scheme, and keeps benchmark
policy and human scores outside the editor being evaluated.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import uuid


BENCH_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BENCH_DIR.parent
DEFAULT_CATALOG = BENCH_DIR / "scenarios.json"
DEFAULT_RESULTS = Path(os.environ.get("AIMAX_BENCH_HOME", "~/.aimax-bench")).expanduser()
DEFAULT_DAEMON_HOME = Path("/tmp/aimax-bench-home")
FIXTURES_DIR = BENCH_DIR / "fixtures"
GATES = ("trust", "continuity", "leverage")
OUTCOMES = ("pass", "fail", "abandoned")
CORE_SUITE = (
    "repo-orientation",
    "diagnose-without-editing",
    "small-feature",
    "unknown-command-discovery",
    "sensitive-action",
    "resume-after-restart",
)
SYMBOL = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")


class BenchError(Exception):
    pass


class Rpc:
    def __init__(self, socket_path: Path, timeout: float = 30.0):
        self.socket_path = Path(socket_path).expanduser()
        self.timeout = timeout

    def call(self, method: str, params: dict | None = None):
        request = {
            "jsonrpc": "2.0",
            "id": uuid.uuid4().hex,
            "method": method,
            "params": params or {},
        }
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(self.timeout)
        try:
            client.connect(str(self.socket_path))
            client.sendall((json.dumps(request) + "\n").encode())
            chunks = bytearray()
            while not chunks.endswith(b"\n"):
                chunk = client.recv(65_536)
                if not chunk:
                    break
                chunks.extend(chunk)
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError) as error:
            raise BenchError(f"RPC unavailable at {self.socket_path}: {error}") from error
        finally:
            client.close()

        if not chunks:
            raise BenchError("daemon closed the RPC connection without a response")
        try:
            response = json.loads(chunks)
        except json.JSONDecodeError as error:
            raise BenchError(f"invalid RPC response: {chunks[:200]!r}") from error
        if "error" in response:
            detail = response["error"].get("message", response["error"])
            raise BenchError(f"RPC {method} failed: {detail}")
        return response.get("result")

    def eval(self, code: str) -> str:
        return self.call("eval", {"code": code})

    def value(self, code: str):
        """Decode printed Scheme scalars when they are also valid JSON."""
        printed = self.eval(code)
        try:
            return json.loads(printed)
        except (json.JSONDecodeError, TypeError):
            if printed == "#t":
                return True
            if printed == "#f":
                return False
            return printed

    def ping(self) -> bool:
        try:
            return self.call("ping") == "pong"
        except BenchError:
            return False


class RunStore:
    def __init__(self, root: Path):
        self.root = Path(root).expanduser().resolve()
        self.runs = self.root / "runs"

    def create(self, run: dict) -> Path:
        path = self.runs / f"{run['run_id']}.json"
        if path.exists():
            raise BenchError(f"run already exists: {path}")
        self._write(path, run)
        return path

    def resolve(self, reference: str) -> Path:
        candidate = Path(reference).expanduser()
        if candidate.is_absolute() or "/" in reference:
            return candidate.resolve()
        suffix = "" if reference.endswith(".json") else ".json"
        return self.runs / f"{reference}{suffix}"

    def load(self, reference: str) -> tuple[Path, dict]:
        path = self.resolve(reference)
        try:
            with path.open() as handle:
                return path, json.load(handle)
        except FileNotFoundError as error:
            raise BenchError(f"unknown run: {reference}") from error
        except json.JSONDecodeError as error:
            raise BenchError(f"invalid run journal {path}: {error}") from error

    def save(self, path: Path, run: dict):
        self._write(path, run)

    def finished(self) -> list[dict]:
        if not self.runs.exists():
            return []
        runs = []
        for path in sorted(self.runs.glob("*.json")):
            try:
                with path.open() as handle:
                    run = json.load(handle)
            except json.JSONDecodeError as error:
                raise BenchError(f"invalid run journal {path}: {error}") from error
            if run.get("status") == "finished":
                runs.append(run)
        return runs

    @staticmethod
    def _write(path: Path, value: dict):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        with temporary.open("x") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)


def load_catalog(path: Path) -> dict:
    try:
        with Path(path).open() as handle:
            catalog = json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise BenchError(f"cannot load scenario catalog {path}: {error}") from error

    tasks = catalog.get("tasks")
    if not isinstance(catalog.get("version"), int) or not isinstance(tasks, list) or not tasks:
        raise BenchError("scenario catalog must have an integer version and non-empty tasks")
    ids = []
    required = ("id", "title", "area", "cadence", "prompt", "setup", "success", "gates")
    for task in tasks:
        if any(key not in task for key in required):
            raise BenchError(f"incomplete scenario: {task!r}")
        if not all(isinstance(task[key], str) and task[key] for key in required[:5]):
            raise BenchError(f"invalid scenario strings: {task.get('id', task)!r}")
        if not all(isinstance(task[key], list) for key in required[5:]):
            raise BenchError(f"invalid scenario lists: {task['id']}")
        if any(gate not in GATES for gate in task["gates"]):
            raise BenchError(f"invalid gate in scenario: {task['id']}")
        ids.append(task["id"])
    if len(ids) != len(set(ids)):
        raise BenchError("scenario IDs must be unique")
    return catalog


def find_scenario(catalog: dict, task_id: str) -> dict:
    for task in catalog["tasks"]:
        if task["id"] == task_id:
            return task
    raise BenchError(f"unknown scenario {task_id!r}; run `bench/aimax-bench list`")


def scheme_string(value: str) -> str:
    encoded = base64.b64encode(value.encode()).decode()
    return f'(base64-decode "{encoded}")'


def checked_symbol(value: str, label: str) -> str:
    if not SYMBOL.fullmatch(value):
        raise BenchError(f"invalid {label}: {value!r}")
    return value


def execute_expression(prompt: str, connector: str | None, model: str | None,
                       permission_mode: str | None, presets: list[str],
                       workspace: Path | None = None) -> str:
    options = []
    if connector:
        options.extend(("'connector", scheme_string(connector)))
    if model:
        options.extend(("'model", scheme_string(model)))
    if permission_mode:
        options.extend(("'permission-mode", f"'{checked_symbol(permission_mode, 'permission mode')}"))
    if presets:
        symbols = " ".join(f"'{checked_symbol(item, 'preset')}" for item in presets)
        options.extend(("'presets", f"(list {symbols})"))
    if workspace is not None:
        directory = str(Path(workspace).resolve()).rstrip("/") + "/"
        options.extend(("'directory", scheme_string(directory)))
    option_list = "(list " + " ".join(options) + ")" if options else "'()"
    return f"(execute* {scheme_string(prompt)} {option_list})"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(now: dt.datetime) -> str:
    return now.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def run_id(task_id: str, now: dt.datetime | None = None) -> str:
    now = now or utc_now()
    stamp = now.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return f"{stamp}-{task_id}-{uuid.uuid4().hex[:6]}"


def git_revision(workspace: Path) -> str | None:
    result = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"], cwd=workspace,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def observe(rpc: Rpc, slug: str) -> dict:
    quoted = scheme_string(slug)
    observation = {"observed_at": iso(utc_now())}
    queries = {
        "agent_status": f"(symbol->string (agent-status {quoted}))",
        "buffer": f"(agent-buf {quoted})",
        "current_buffer": "(current-buffer)",
    }
    for key, expression in queries.items():
        try:
            observation[key] = rpc.value(expression)
        except BenchError as error:
            observation[f"{key}_error"] = str(error)

    try:
        transcript = rpc.value(f"(buffer-text (agent-buf {quoted}))")
        if isinstance(transcript, str):
            observation["transcript_bytes"] = len(transcript.encode())
            observation["transcript_sha256"] = hashlib.sha256(transcript.encode()).hexdigest()
    except BenchError as error:
        observation["transcript_error"] = str(error)
    return observation


def start_run(catalog: dict, store: RunStore, rpc: Rpc, task_id: str, prompt: str,
              connector: str | None = None, model: str | None = None,
              permission_mode: str | None = None, presets: list[str] | None = None,
              workspace: Path | None = None, now: dt.datetime | None = None) -> tuple[Path, dict]:
    scenario = find_scenario(catalog, task_id)
    workspace = (workspace or Path.cwd()).resolve()
    presets = presets or []
    if not workspace.is_dir():
        raise BenchError(f"workspace is not a directory: {workspace}")
    slug = rpc.value(execute_expression(
        prompt, connector, model, permission_mode, presets, workspace
    ))
    if not isinstance(slug, str) or not slug:
        raise BenchError(f"execute* returned an invalid agent slug: {slug!r}")
    now = now or utc_now()
    run = {
        "schema_version": 1,
        "catalog_version": catalog["version"],
        "run_id": run_id(task_id, now),
        "status": "started",
        "started_at": iso(now),
        "scenario": scenario,
        "prompt": prompt,
        "agent_slug": slug,
        "context": {
            "socket": str(rpc.socket_path),
            "workspace": str(workspace),
            "git_revision": git_revision(workspace),
            "connector": connector,
            "model": model,
            "permission_mode": permission_mode,
            "presets": presets,
        },
        "initial_observation": observe(rpc, slug),
    }
    return store.create(run), run


def continue_run(store: RunStore, rpc: Rpc, reference: str, prompt: str) -> tuple[Path, dict]:
    path, run = store.load(reference)
    if run.get("status") != "started":
        raise BenchError(f"run is already {run.get('status', 'invalid')}")
    thread = run["initial_observation"]["buffer"]
    result = rpc.eval(
        f"(agent-continue! {scheme_string(thread)} {scheme_string(prompt)})"
    )
    run.setdefault("continuations", []).append({"sent_at": iso(utc_now()), "prompt": prompt})
    store.save(path, run)
    return path, {"run": run, "result": result}


def prepare_fixture(name: str, destination: Path) -> Path:
    if not SYMBOL.fullmatch(name):
        raise BenchError(f"invalid fixture name: {name!r}")
    source = FIXTURES_DIR / name
    destination = destination.expanduser().resolve()
    if not source.is_dir():
        raise BenchError(f"unknown fixture: {name}")
    if destination.exists():
        raise BenchError(f"fixture destination already exists: {destination}")
    shutil.copytree(source, destination)
    result = subprocess.run(
        ["git", "init", "-q"], cwd=destination, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if result.returncode != 0:
        raise BenchError(f"could not initialize fixture repository: {result.stderr.strip()}")
    return destination


def normalize_score(scenario: dict, values: dict) -> dict:
    outcome = values.get("outcome")
    intended = values.get("intended_state")
    interventions = values.get("interventions")
    reuse = values.get("reuse")
    if outcome not in OUTCOMES:
        raise BenchError("outcome must be pass, fail, or abandoned")
    if not isinstance(intended, bool):
        raise BenchError("intended-state must be yes or no")
    if not isinstance(interventions, int) or interventions < 0:
        raise BenchError("interventions must be a non-negative integer")
    if not isinstance(reuse, int) or reuse not in range(1, 6):
        raise BenchError("reuse must be an integer from 1 to 5")
    for gate in scenario["gates"]:
        if not isinstance(values.get(gate), bool):
            raise BenchError(f"{gate} must be scored for this scenario")
    return {
        "outcome": outcome,
        "intended_state": intended,
        "interventions": interventions,
        "reuse": reuse,
        "trust": values.get("trust"),
        "continuity": values.get("continuity"),
        "leverage": values.get("leverage"),
        "notes": values.get("notes") or "",
    }


def successful(score: dict) -> bool:
    return (score["outcome"] == "pass" and score["intended_state"] and
            all(score.get(gate) is not False for gate in GATES))


def run_successful(run: dict) -> bool:
    return successful(run["score"]) and all(check.get("passed") for check in run.get("checks", []))


def finish_run(store: RunStore, rpc: Rpc | None, reference: str, values: dict,
               checks: list[str] | None = None, now: dt.datetime | None = None) -> tuple[Path, dict]:
    path, run = store.load(reference)
    if run.get("status") != "started":
        raise BenchError(f"run is already {run.get('status', 'invalid')}")
    score = normalize_score(run["scenario"], values)
    now = now or utc_now()
    finished = dt.datetime.fromisoformat(run["started_at"].replace("Z", "+00:00"))
    run["status"] = "finished"
    run["finished_at"] = iso(now)
    run["duration_seconds"] = max(0, int((now - finished).total_seconds()))
    run["score"] = score
    if rpc:
        try:
            run["final_observation"] = observe(rpc, run["agent_slug"])
            run["checks"] = evaluate_checks(rpc, checks or [])
        except BenchError as error:
            run["observation_error"] = str(error)
    else:
        run["observation_error"] = "finished offline by operator"
    store.save(path, run)
    return path, run


def rescore_run(store: RunStore, reference: str, values: dict,
                now: dt.datetime | None = None) -> tuple[Path, dict]:
    """Correct an operator score without rewriting observations or history."""
    path, run = store.load(reference)
    if run.get("status") != "finished":
        raise BenchError("only a finished run can be rescored")
    run["score"] = normalize_score(run["scenario"], values)
    run["rescored_at"] = iso(now or utc_now())
    store.save(path, run)
    return path, run


def invalidate_run(store: RunStore, reference: str, reason: str,
                   now: dt.datetime | None = None) -> tuple[Path, dict]:
    path, run = store.load(reference)
    if run.get("status") != "started":
        raise BenchError(f"run is already {run.get('status', 'invalid')}")
    if not reason.strip():
        raise BenchError("an invalid run requires a reason")
    run["status"] = "invalid"
    run["invalidated_at"] = iso(now or utc_now())
    run["invalid_reason"] = reason.strip()
    store.save(path, run)
    return path, run


def evaluate_checks(rpc: Rpc, expressions: list[str]) -> list[dict]:
    results = []
    for expression in expressions:
        try:
            printed = rpc.eval(expression)
            results.append({"expression": expression, "result": printed, "passed": printed != "#f"})
        except BenchError as error:
            results.append({"expression": expression, "error": str(error), "passed": False})
    return results


def ratio(part: int, total: int) -> float | None:
    return round(part / total, 3) if total else None


def average(values: list[int]) -> float | None:
    return round(sum(values) / len(values), 2) if values else None


def report(store: RunStore, task_id: str | None = None) -> dict:
    runs = store.finished()
    if task_id:
        runs = [run for run in runs if run["scenario"]["id"] == task_id]
    scores = [run["score"] for run in runs]
    successes = sum(run_successful(run) for run in runs)
    zero = sum(run_successful(run) and run["score"]["interventions"] == 0 for run in runs)
    gates = {}
    for gate in GATES:
        values = [score[gate] for score in scores if score.get(gate) is not None]
        passed = sum(values)
        gates[gate] = {
            "evaluated": len(values),
            "passed": passed,
            "all_passed": bool(values) and passed == len(values),
        }
    by_task = {}
    for run in runs:
        key = run["scenario"]["id"]
        bucket = by_task.setdefault(key, {"runs": 0, "successful": 0})
        bucket["runs"] += 1
        bucket["successful"] += int(run_successful(run))
    for bucket in by_task.values():
        bucket["success_rate"] = ratio(bucket["successful"], bucket["runs"])
    return {
        "runs": len(runs),
        "successful": successes,
        "success_rate": ratio(successes, len(runs)),
        "zero_intervention": zero,
        "zero_intervention_rate": ratio(zero, len(runs)),
        "median_interventions": statistics.median([s["interventions"] for s in scores]) if scores else None,
        "median_duration_seconds": statistics.median([r["duration_seconds"] for r in runs]) if runs else None,
        "average_reuse": average([s["reuse"] for s in scores]),
        "gates": gates,
        "by_task": by_task,
    }


def render_suite(store: RunStore, catalog: dict, output: Path) -> Path:
    finished = store.finished()
    tasks = {task["id"]: task for task in catalog["tasks"]}
    latest = {}
    for run in finished:
        task_id = run["scenario"]["id"]
        if task_id in CORE_SUITE and (
            task_id not in latest or run.get("finished_at", "") > latest[task_id].get("finished_at", "")
        ):
            latest[task_id] = run
    passing = sum(task_id in latest and run_successful(latest[task_id]) for task_id in CORE_SUITE)
    valid_runs = [run for run in finished if run["scenario"]["id"] in CORE_SUITE]
    zero = sum(run_successful(run) and run["score"]["interventions"] == 0 for run in valid_runs)

    cards = []
    for task_id in CORE_SUITE:
        task = tasks[task_id]
        run = latest.get(task_id)
        if run is None:
            state, label, detail = "pending", "Not run", "No valid finished run yet."
            metrics = ""
        else:
            ok = run_successful(run)
            state, label = ("pass", "Pass") if ok else ("fail", "Fail")
            score = run["score"]
            detail = score.get("notes") or "No operator note."
            metrics = (
                f'<div class="mini"><span>{run.get("duration_seconds", 0)}s</span>'
                f'<span>{score["interventions"]} intervention(s)</span>'
                f'<span>reuse {score["reuse"]}/5</span></div>'
            )
        cards.append(
            f'<article class="card {state}"><div class="cardtop"><div>'
            f'<div class="area">{html.escape(task["area"])} · {html.escape(task["cadence"])}</div>'
            f'<h2>{html.escape(task["title"])}</h2></div><span class="badge">{label}</span></div>'
            f'<p>{html.escape(detail)}</p>{metrics}</article>'
        )

    generated = iso(utc_now()).replace("T", " ").replace("Z", " UTC")
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ai-max core acceptance suite</title><style>
:root{{--bg:#0b0d10;--panel:#13171c;--line:#29313a;--text:#e9eef3;--muted:#94a0ac;--green:#53d18b;--red:#ff7d7d;--amber:#efc46b;--blue:#79b8ff}}*{{box-sizing:border-box}}body{{margin:0;background:radial-gradient(circle at 15% 0,#142231 0,transparent 38rem),var(--bg);color:var(--text);font:15px/1.55 ui-sans-serif,system-ui,sans-serif}}main{{width:min(1120px,calc(100% - 32px));margin:54px auto 80px}}header{{display:flex;justify-content:space-between;gap:24px;align-items:start}}h1{{font-size:clamp(34px,6vw,58px);line-height:1;margin:6px 0 12px;letter-spacing:-.05em}}h2{{font-size:19px;margin:4px 0 0}}.eyebrow,.area{{font:12px/1.4 ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--blue)}}.muted,.card p{{color:var(--muted)}}.summary{{font-size:22px;font-weight:750;color:{'var(--green)' if passing == len(CORE_SUITE) else 'var(--amber)'};white-space:nowrap}}.metrics{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:32px 0 14px}}.metric,.card,.note{{border:1px solid var(--line);background:rgba(19,23,28,.94);border-radius:14px}}.metric{{padding:18px}}.metric strong{{display:block;font-size:27px}}.metric span{{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}}.cards{{display:grid;grid-template-columns:repeat(2,1fr);gap:12px}}.card{{padding:20px;border-top:3px solid var(--amber)}}.card.pass{{border-top-color:var(--green)}}.card.fail{{border-top-color:var(--red)}}.cardtop{{display:flex;justify-content:space-between;gap:18px}}.badge{{height:min-content;border-radius:999px;padding:5px 10px;background:#2d2a1c;color:var(--amber);font-weight:700;font-size:12px}}.pass .badge{{background:#173827;color:var(--green)}}.fail .badge{{background:#3c2020;color:var(--red)}}.card p{{min-height:48px}}.mini{{display:flex;gap:8px;flex-wrap:wrap}}.mini span{{border:1px solid var(--line);border-radius:999px;padding:4px 8px;font-size:12px}}.note{{margin-top:12px;padding:18px}}code{{color:#bad9ff}}footer{{margin-top:22px;color:var(--muted);font-size:12px}}@media(max-width:760px){{header{{display:block}}.summary{{margin-top:18px}}.metrics,.cards{{grid-template-columns:1fr 1fr}}}}@media(max-width:520px){{.metrics,.cards{{grid-template-columns:1fr}}}}
</style></head><body><main><header><div><div class="eyebrow">ai-max · internal dogfood</div><h1>Core acceptance suite</h1><p class="muted">Six distinct workflows, scored on outcomes rather than leaderboard comparability.</p></div><div class="summary">{passing} / {len(CORE_SUITE)} passing</div></header>
<div class="metrics"><div class="metric"><strong>{passing}/{len(CORE_SUITE)}</strong><span>Scenario coverage</span></div><div class="metric"><strong>{len(valid_runs)}</strong><span>Valid runs</span></div><div class="metric"><strong>{zero}</strong><span>Zero-intervention passes</span></div><div class="metric"><strong>{catalog['version']}</strong><span>Catalog version</span></div></div>
<div class="cards">{''.join(cards)}</div><div class="note"><strong>Acceptance rule.</strong> Every scenario needs a valid passing run. A failed run remains in the history; infrastructure-invalid runs are excluded. Flaky or failed scenarios should pass twice consecutively before being considered stable.</div>
<footer>Generated {generated} · journals: <code>{html.escape(str(store.runs))}</code></footer></main></body></html>"""
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(document)
    return output


def daemon_pid_path(home: Path) -> Path:
    return home / "bench-daemon.pid"


def attach_provider_config(source_home: Path, benchmark_home: Path):
    source_home = source_home.expanduser().resolve()
    benchmark_home = benchmark_home.expanduser().resolve()
    benchmark_home.mkdir(parents=True, exist_ok=True)
    attached = []
    for name in ("ai-config.scm", "secrets.scm"):
        source = source_home / name
        if not source.is_file():
            if name == "ai-config.scm":
                raise BenchError(f"provider config not found: {source}")
            continue
        destination = benchmark_home / name
        if destination.exists() or destination.is_symlink():
            if destination.resolve() != source.resolve():
                raise BenchError(f"benchmark config already points elsewhere: {destination}")
        else:
            destination.symlink_to(source)
        attached.append(name)
    return attached


def daemon_start(home: Path, project: Path, port: int, app_port: int, timeout: float) -> Rpc:
    home = home.expanduser().resolve()
    project = project.expanduser().resolve()
    socket_path = home / "sock"
    rpc = Rpc(socket_path)
    if rpc.ping():
        raise BenchError(f"daemon is already running at {socket_path}")
    home.mkdir(parents=True, exist_ok=True)
    log = (home / "daemon.log").open("a")
    environment = os.environ.copy()
    environment.update({
        "AIMAX_HOME": str(home),
        "AIMAX_PORT": str(port),
        "AIMAX_APP_PORT": str(app_port),
        "AIMAX_NAME": "dogfood",
    })
    process = subprocess.Popen(
        ["mix", "run", "--no-halt"], cwd=project, env=environment,
        stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    daemon_pid_path(home).write_text(f"{process.pid}\n")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise BenchError(f"daemon exited with {process.returncode}; see {home / 'daemon.log'}")
        if rpc.ping():
            return rpc
        time.sleep(0.2)
    raise BenchError(f"daemon did not start within {timeout:g}s; see {home / 'daemon.log'}")


def daemon_stop(home: Path, timeout: float):
    home = home.expanduser().resolve()
    rpc = Rpc(home / "sock")
    try:
        result = rpc.call("shutdown")
    except BenchError as error:
        raise BenchError(f"could not request daemon shutdown: {error}") from error
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not rpc.ping():
            daemon_pid_path(home).unlink(missing_ok=True)
            return result
        time.sleep(0.2)
    raise BenchError(f"daemon did not stop within {timeout:g}s")


def parse_yes_no(value: str | None) -> bool | None:
    if value is None:
        return None
    lowered = value.lower()
    if lowered in ("yes", "true", "1"):
        return True
    if lowered in ("no", "false", "0"):
        return False
    raise argparse.ArgumentTypeError("expected yes or no")


def objective(args, scenario: dict) -> str:
    if args.objective and args.objective_file:
        raise BenchError("use only one of --objective and --objective-file")
    if args.objective_file:
        return Path(args.objective_file).read_text()
    return args.objective or scenario["prompt"]


def format_percent(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.1f}%"


def print_items(heading: str, values: list[str]):
    print(heading)
    for value in values:
        print(f"  - {value}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument(
        "--home",
        type=Path,
        default=Path(os.environ.get("AIMAX_HOME", str(DEFAULT_DAEMON_HOME))).expanduser(),
    )
    parser.add_argument("--socket", type=Path, default=None)
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list")
    listing.add_argument("--area")
    listing.add_argument("--cadence")

    start = sub.add_parser("start")
    start.add_argument("task_id")
    start.add_argument("--objective")
    start.add_argument("--objective-file")
    start.add_argument("--connector")
    start.add_argument("--model")
    start.add_argument("--permission-mode", choices=("ask", "auto", "approve"))
    start.add_argument("--presets", default="")
    start.add_argument("--workspace", type=Path, default=Path.cwd())

    continuation = sub.add_parser("continue")
    continuation.add_argument("run_id")
    continuation.add_argument("--objective")
    continuation.add_argument("--objective-file")

    wait = sub.add_parser("wait")
    wait.add_argument("run_id")
    wait.add_argument("--timeout", type=float, default=1800)
    wait.add_argument("--interval", type=float, default=1)

    show = sub.add_parser("show")
    show.add_argument("run_id")
    show.add_argument("--transcript", action="store_true")

    finish = sub.add_parser("finish")
    finish.add_argument("run_id")
    finish.add_argument("--outcome", required=True, choices=OUTCOMES)
    finish.add_argument("--intended-state", required=True, type=parse_yes_no)
    finish.add_argument("--interventions", required=True, type=int)
    finish.add_argument("--reuse", required=True, type=int)
    for gate in GATES:
        finish.add_argument(f"--{gate}", type=parse_yes_no)
    finish.add_argument("--notes", default="")
    finish.add_argument("--check", action="append", default=[])
    finish.add_argument("--offline", action="store_true")

    rescore = sub.add_parser("rescore")
    rescore.add_argument("run_id")
    rescore.add_argument("--outcome", required=True, choices=OUTCOMES)
    rescore.add_argument("--intended-state", required=True, type=parse_yes_no)
    rescore.add_argument("--interventions", required=True, type=int)
    rescore.add_argument("--reuse", required=True, type=int)
    for gate in GATES:
        rescore.add_argument(f"--{gate}", type=parse_yes_no)
    rescore.add_argument("--notes", default="")

    invalid = sub.add_parser("invalidate")
    invalid.add_argument("run_id")
    invalid.add_argument("--reason", required=True)

    summary = sub.add_parser("report")
    summary.add_argument("--task")
    summary.add_argument("--json", action="store_true")

    render = sub.add_parser("render")
    render.add_argument("--output", type=Path, default=BENCH_DIR / "results" / "core-suite.html")

    evaluate = sub.add_parser("eval")
    evaluate.add_argument("expression")

    fixture = sub.add_parser("fixture")
    fixture.add_argument("name")
    fixture.add_argument("destination", type=Path)

    daemon = sub.add_parser("daemon")
    daemon_sub = daemon.add_subparsers(dest="daemon_command", required=True)
    daemon_start_parser = daemon_sub.add_parser("start")
    daemon_start_parser.add_argument("--project", type=Path, default=PROJECT_ROOT)
    daemon_start_parser.add_argument("--port", type=int, default=4104)
    daemon_start_parser.add_argument("--app-port", type=int, default=4105)
    daemon_start_parser.add_argument("--timeout", type=float, default=30)
    daemon_start_parser.add_argument("--config-from", type=Path)
    daemon_stop_parser = daemon_sub.add_parser("stop")
    daemon_stop_parser.add_argument("--timeout", type=float, default=30)
    restart = daemon_sub.add_parser("restart")
    restart.add_argument("--project", type=Path, default=PROJECT_ROOT)
    restart.add_argument("--port", type=int, default=4104)
    restart.add_argument("--app-port", type=int, default=4105)
    restart.add_argument("--timeout", type=float, default=30)
    restart.add_argument("--config-from", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    store = RunStore(args.results)
    socket_path = args.socket or args.home.expanduser() / "sock"
    rpc = Rpc(socket_path)

    if args.command == "daemon":
        if args.socket:
            raise BenchError("--socket is not used by daemon control; --home determines its socket")
        if args.daemon_command == "start":
            if args.config_from:
                attached = attach_provider_config(args.config_from, args.home)
                print(f"attached provider config: {', '.join(attached)}")
            started = daemon_start(args.home, args.project, args.port, args.app_port, args.timeout)
            print(f"daemon ready at {started.socket_path}")
        elif args.daemon_command == "stop":
            print(daemon_stop(args.home, args.timeout))
        else:
            daemon_stop(args.home, args.timeout)
            if args.config_from:
                attached = attach_provider_config(args.config_from, args.home)
                print(f"attached provider config: {', '.join(attached)}")
            started = daemon_start(args.home, args.project, args.port, args.app_port, args.timeout)
            print(f"daemon restarted at {started.socket_path}")
        return 0

    if args.command == "fixture":
        print(prepare_fixture(args.name, args.destination))
        return 0

    catalog = load_catalog(args.catalog)
    if args.command == "list":
        tasks = [task for task in catalog["tasks"]
                 if (not args.area or task["area"] == args.area)
                 and (not args.cadence or task["cadence"] == args.cadence)]
        print(f"{catalog['title']} - {len(tasks)} scenarios\n")
        for task in tasks:
            print(f"{task['id']}  [{task['cadence']} / {task['area']}]\n  {task['title']}")
    elif args.command == "start":
        scenario = find_scenario(catalog, args.task_id)
        prompt = objective(args, scenario)
        presets = [item.strip() for item in args.presets.split(",") if item.strip()]
        path, run = start_run(
            catalog, store, rpc, args.task_id, prompt, args.connector, args.model,
            args.permission_mode, presets, args.workspace,
        )
        print(f"started {run['run_id']} as agent {run['agent_slug']}\njournal: {path}\n")
        print(f"TASK\n{prompt}\n")
        print_items("SETUP", scenario["setup"])
        print_items("SUCCESS", scenario["success"])
        print(f"GATES\n  {', '.join(scenario['gates'])}")
    elif args.command == "continue":
        if args.objective and args.objective_file:
            raise BenchError("use only one of --objective and --objective-file")
        prompt = Path(args.objective_file).read_text() if args.objective_file else args.objective
        if not prompt:
            raise BenchError("continue requires --objective or --objective-file")
        path, continued = continue_run(store, rpc, args.run_id, prompt)
        print(f"continued {continued['run']['run_id']} as agent {continued['run']['agent_slug']}\njournal: {path}")
    elif args.command == "wait":
        _, run = store.load(args.run_id)
        deadline = time.monotonic() + args.timeout
        while True:
            current = observe(rpc, run["agent_slug"])
            status = current.get("agent_status")
            if status in ("idle", "dead", "needs_attention"):
                print(json.dumps(current, indent=2, sort_keys=True))
                break
            if time.monotonic() >= deadline:
                raise BenchError(f"timed out waiting for {run['agent_slug']}; last status: {status}")
            time.sleep(args.interval)
    elif args.command == "show":
        _, run = store.load(args.run_id)
        print(json.dumps(run, indent=2, sort_keys=True))
        if args.transcript:
            print("\n--- live transcript ---")
            print(rpc.value(f"(buffer-text (agent-buf {scheme_string(run['agent_slug'])}))"))
    elif args.command == "finish":
        values = {key: getattr(args, key) for key in
                  ("outcome", "intended_state", "interventions", "reuse", *GATES, "notes")}
        path, run = finish_run(store, None if args.offline else rpc, args.run_id, values, args.check)
        verdict = "satisfied" if run_successful(run) else "not satisfied"
        print(f"finished {run['run_id']} - {verdict}\njournal: {path}")
    elif args.command == "rescore":
        values = {key: getattr(args, key) for key in
                  ("outcome", "intended_state", "interventions", "reuse", *GATES, "notes")}
        path, run = rescore_run(store, args.run_id, values)
        verdict = "satisfied" if run_successful(run) else "not satisfied"
        print(f"rescored {run['run_id']} - {verdict}\njournal: {path}")
    elif args.command == "invalidate":
        path, run = invalidate_run(store, args.run_id, args.reason)
        print(f"invalidated {run['run_id']} - excluded from reports\njournal: {path}")
    elif args.command == "report":
        result = report(store, args.task)
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print(f"ai-max dogfood - {result['runs']} finished runs")
            print(f"successful:            {format_percent(result['success_rate'])}")
            print(f"zero-intervention:     {format_percent(result['zero_intervention_rate'])}")
            print(f"median interventions:  {result['median_interventions'] if result['median_interventions'] is not None else 'n/a'}")
            print(f"median duration:       {result['median_duration_seconds'] if result['median_duration_seconds'] is not None else 'n/a'}s")
            print(f"average reuse:         {result['average_reuse'] if result['average_reuse'] is not None else 'n/a'} / 5\n")
            for gate in GATES:
                item = result["gates"][gate]
                verdict = "NOT EVALUATED" if not item["evaluated"] else ("PASS" if item["all_passed"] else "NOT MET")
                print(f"{gate + ':':13} {verdict} ({item['passed']}/{item['evaluated']})")
    elif args.command == "render":
        print(render_suite(store, catalog, args.output))
    elif args.command == "eval":
        print(rpc.eval(args.expression))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BenchError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
