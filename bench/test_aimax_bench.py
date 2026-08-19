import datetime as dt
import json
from pathlib import Path
import socketserver
import tempfile
import threading
import unittest

import aimax_bench as bench


class FakeRpc:
    socket_path = Path("/tmp/fake-aimax.sock")

    def __init__(self):
        self.executed = []

    def value(self, expression):
        self.executed.append(expression)
        if "(execute*" in expression:
            return "a1"
        if "agent-status" in expression:
            return "idle"
        if expression.startswith("(agent-buf"):
            return "*chat:a1*"
        if expression == "(current-buffer)":
            return "*scratch*"
        if expression.startswith("(buffer-text"):
            return ">>> you: do it\nDone."
        raise AssertionError(expression)

    def eval(self, expression):
        self.executed.append(expression)
        return "#f" if expression == "bad" else "#t"


class RpcHandler(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline())
        self.server.requests.append(request)
        response = {"jsonrpc": "2.0", "id": request["id"], "result": '"pong"'}
        self.wfile.write((json.dumps(response) + "\n").encode())


class BenchTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.catalog = bench.load_catalog(bench.DEFAULT_CATALOG)
        self.store = bench.RunStore(self.root / "results")
        self.rpc = FakeRpc()

    def tearDown(self):
        self.temporary.cleanup()

    def test_catalog_is_stable_and_filterable(self):
        tasks = self.catalog["tasks"]
        self.assertEqual(15, len(tasks))
        self.assertEqual(3, sum(task["cadence"] == "daily" for task in tasks))
        self.assertEqual(2, sum(task["area"] == "control" for task in tasks))

    def test_rpc_uses_the_public_json_rpc_protocol(self):
        path = self.root / "rpc.sock"
        server = socketserver.UnixStreamServer(str(path), RpcHandler)
        server.requests = []
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        try:
            rpc = bench.Rpc(path)
            self.assertEqual("pong", rpc.value("(hello)"))
        finally:
            thread.join(timeout=2)
            server.server_close()
        self.assertEqual("eval", server.requests[0]["method"])
        self.assertEqual("(hello)", server.requests[0]["params"]["code"])

    def test_execute_expression_does_not_interpolate_prompt_text(self):
        prompt = 'quote " and Scheme ) (buffer-kill! "important")'
        expression = bench.execute_expression(
            prompt, "api", "test:model", "ask", ["aimax", "project"]
        )
        self.assertNotIn(prompt, expression)
        self.assertIn("base64-decode", expression)
        self.assertIn("'permission-mode 'ask", expression)
        self.assertIn("'presets (list 'aimax 'project)", expression)

    def test_execute_expression_establishes_workspace_in_editor_state(self):
        expression = bench.execute_expression(
            "orient", "api", "test:model", "approve", ["aimax"], self.root
        )

        self.assertIn("'directory", expression)
        self.assertIn("(execute*", expression)

    def test_start_drives_a_real_agent_surface_and_snapshots_observation(self):
        now = dt.datetime(2026, 8, 18, 9, 30, tzinfo=dt.timezone.utc)
        path, run = bench.start_run(
            self.catalog,
            self.store,
            self.rpc,
            "repo-orientation",
            "orient here",
            connector="api",
            model="test:model",
            workspace=bench.PROJECT_ROOT,
            now=now,
        )
        self.assertTrue(path.exists())
        self.assertEqual("a1", run["agent_slug"])
        self.assertEqual("idle", run["initial_observation"]["agent_status"])
        self.assertEqual("*chat:a1*", run["initial_observation"]["buffer"])
        self.assertEqual(64, len(run["initial_observation"]["transcript_sha256"]))
        self.assertIn("(execute*", self.rpc.executed[0])
        self.assertIn("'directory", self.rpc.executed[0])

    def test_continue_reuses_the_recorded_agent_and_preserves_the_prompt(self):
        _, run = bench.start_run(
            self.catalog, self.store, self.rpc, "resume-after-restart", "phase one",
            workspace=bench.PROJECT_ROOT,
        )

        _, continued = bench.continue_run(self.store, self.rpc, run["run_id"], "phase two")

        self.assertEqual("#t", continued["result"])
        self.assertIn("agent-continue!", self.rpc.executed[-1])
        _, saved = self.store.load(run["run_id"])
        self.assertEqual("phase two", saved["continuations"][0]["prompt"])

    def test_fixture_preparation_is_copy_on_write_and_refuses_reuse(self):
        destination = self.root / "diagnose-copy"
        prepared = bench.prepare_fixture("diagnose", destination)

        self.assertTrue((prepared / ".git").is_dir())
        self.assertTrue((prepared / "calculator.py").is_file())
        with self.assertRaisesRegex(bench.BenchError, "already exists"):
            bench.prepare_fixture("diagnose", destination)

    def test_finish_scores_checks_and_report(self):
        path, run = bench.start_run(
            self.catalog, self.store, self.rpc, "repo-orientation", "orient",
            workspace=bench.PROJECT_ROOT,
            now=dt.datetime(2026, 8, 18, 9, 30, tzinfo=dt.timezone.utc),
        )
        values = {
            "outcome": "pass",
            "intended_state": True,
            "interventions": 0,
            "reuse": 5,
            "trust": True,
            "leverage": True,
            "continuity": None,
            "notes": "clean",
        }
        _, finished = bench.finish_run(
            self.store, self.rpc, run["run_id"], values, checks=["good", "bad"],
            now=dt.datetime(2026, 8, 18, 9, 32, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(path, self.store.resolve(run["run_id"]))
        self.assertTrue(bench.successful(finished["score"]))
        self.assertFalse(bench.run_successful(finished))
        self.assertEqual([True, False], [check["passed"] for check in finished["checks"]])

        corrected = dict(values, outcome="fail", notes="transcript review")
        _, rescored = bench.rescore_run(self.store, run["run_id"], corrected)
        self.assertEqual("fail", rescored["score"]["outcome"])
        self.assertIn("rescored_at", rescored)

        report = bench.report(self.store)
        self.assertEqual(1, report["runs"])
        self.assertEqual(0.0, report["zero_intervention_rate"])
        self.assertEqual(120, report["median_duration_seconds"])
        self.assertTrue(report["gates"]["trust"]["all_passed"])
        self.assertFalse(report["gates"]["continuity"]["all_passed"])

        rendered = bench.render_suite(self.store, self.catalog, self.root / "suite.html")
        page = rendered.read_text()
        self.assertIn("Core acceptance suite", page)
        self.assertIn("Orient in an unfamiliar repository", page)
        self.assertIn("0 / 6 passing", page)

    def test_required_gates_are_not_inferred(self):
        scenario = bench.find_scenario(self.catalog, "resume-after-restart")
        with self.assertRaisesRegex(bench.BenchError, "continuity must be scored"):
            bench.normalize_score(
                scenario,
                {
                    "outcome": "pass",
                    "intended_state": True,
                    "interventions": 0,
                    "reuse": 5,
                    "trust": True,
                    "leverage": True,
                },
            )

    def test_infrastructure_failures_can_be_invalidated_without_diluting_results(self):
        _, run = bench.start_run(
            self.catalog, self.store, self.rpc, "repo-orientation", "orient",
            workspace=bench.PROJECT_ROOT,
        )
        _, invalid = bench.invalidate_run(self.store, run["run_id"], "provider key missing")
        self.assertEqual("invalid", invalid["status"])
        self.assertEqual(0, bench.report(self.store)["runs"])

    def test_provider_config_is_attached_without_copying_secrets(self):
        source = self.root / "real-home"
        target = self.root / "isolated-home"
        source.mkdir()
        (source / "ai-config.scm").write_text('(load "secrets.scm")\n')
        (source / "secrets.scm").write_text("secret material\n")

        attached = bench.attach_provider_config(source, target)

        self.assertEqual(["ai-config.scm", "secrets.scm"], attached)
        self.assertTrue((target / "ai-config.scm").is_symlink())
        self.assertTrue((target / "secrets.scm").is_symlink())
        self.assertEqual((source / "secrets.scm").resolve(), (target / "secrets.scm").resolve())


if __name__ == "__main__":
    unittest.main()
