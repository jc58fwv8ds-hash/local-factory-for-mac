#!/usr/bin/env python3
"""Run the frozen B.5 suite, one task at a time, through `HarnessKernelPilot --suite-task`.

python3 run_suite.py --candidate <checkout> --out <dir> [--model <model>] [--only b5-01]
Default backend (2026-10-06): Backburner (Qwen3.8-27B IQ4_XS, OpenAI-compatible at 127.0.0.1:8080), ~2x faster than Ollama with
equal or better success on C2. Start it first (`~/backburner/scripts/serve.sh`, or let the App start it). Ollama models still work
with an explicit `--model <ollama model>`.
Refuses to run unless every frozen file still matches SUITE-FREEZE.json. Never retries a task: one run per task,
its kpi.json is appended to <out>/results.jsonl as measured (failures included)."""
import argparse, json, os, subprocess, sys, time, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from freeze_suite import EVAL, manifest

BACKBURNER = "openai:qwen3.8-27b-iq4xs"

def require_openai_endpoint(models):
    """Fail before the first task (not 22 times) when an OpenAI-compatible model is selected but its server is down."""
    if not any(m and m.startswith("openai:") for m in models): return None
    url = os.environ.get("HARNESS_OPENAI_COMPATIBLE_URL", "http://127.0.0.1:8080/v1/chat/completions")
    health = url.split("/v1/")[0] + "/health"
    try:
        with urllib.request.urlopen(health, timeout=3) as r:
            if r.status == 200: return url
    except OSError: pass
    sys.exit(f"OpenAI-compatible server not reachable at {health}; start Backburner (~/backburner/scripts/serve.sh) first")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True); ap.add_argument("--model", default=BACKBURNER)
    ap.add_argument("--out", required=True); ap.add_argument("--only"); ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--suite", default="suite-b5")
    ap.add_argument("--scope", choices=["selector", "package"], default="package")
    ap.add_argument("--proposal-tokens", type=int, default=2048)
    ap.add_argument("--secondary", help="gated fallback model, e.g. openai:qwen@t0.7")
    ap.add_argument("--examiner", action="store_true", help="independent examiner check after tests pass (off by default)")
    ap.add_argument("--examples", action="store_true", help="example check for the user after tests pass (off by default)")
    ap.add_argument("--clarify", choices=["self", "oracle"], help="settle ambiguous points before building (candidate 3)")
    ap.add_argument("--gated", action="store_true", help="examiner / example check only when a risk signal flags the change")
    a = ap.parse_args()
    endpoint = require_openai_endpoint([a.model, a.secondary])
    SUITE = EVAL / a.suite
    freeze = json.loads((SUITE / "SUITE-FREEZE.json").read_text())
    if manifest(SUITE) != freeze["files"]: sys.exit("suite differs from SUITE-FREEZE.json; refusing to run")
    out = Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    done = set()
    if (out / "results.jsonl").exists():
        done = {json.loads(l)["id"] for l in (out / "results.jsonl").read_text().splitlines() if l.strip()}
    pilot = Path(a.candidate).resolve() / ".build/debug/HarnessKernelPilot"
    # 2026-10-11: 別の場所でビルドしたまま古い実行ファイルで 2 時間測ってしまったので、ソースより古ければ止める
    # The pilot does not link the App (HarnessApp*, HarnessCoreChecks), so App-only edits do not make it stale (2026-10-19).
    newest = max(f.stat().st_mtime for f in (Path(a.candidate).resolve() / "Sources").rglob("*.swift")
                 if not f.relative_to(Path(a.candidate).resolve() / "Sources").parts[0].startswith(("HarnessApp", "HarnessCoreChecks")))
    if not pilot.exists() or pilot.stat().st_mtime < newest:
        sys.exit("実行ファイルがソースより古いです。先に swift build --build-system native を実行してください")
    for task in sorted((SUITE / "tasks").glob("*-*.json")):
        tid = task.stem
        if (a.only and tid != a.only) or tid in done: continue
        start = time.time()
        print(f"{tid}: running", flush=True)
        try:
            p = subprocess.run([str(pilot), "--suite-task", str(Path(a.candidate).resolve()), str(task), a.model, str(out / "runs")]
                               + [f"scope={a.scope}"]
                               + ([f"proposalTokens={a.proposal_tokens}"] if a.proposal_tokens != 2048 else [])
                               + ([f"secondary={a.secondary}"] if a.secondary else [])
                               + (["examiner=on"] if a.examiner else [])
                               + (["examples=on"] if a.examples else []) + (["gated=on"] if a.gated else [])
                               + ([f"clarify={a.clarify}"] if a.clarify else []),
                               capture_output=True, text=True, timeout=a.timeout,
                               env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                                    **({"HARNESS_OPENAI_COMPATIBLE_URL": endpoint} if endpoint else {})})
            start_json = p.stdout.rfind("{\n  \"")
            kpi = json.loads(p.stdout[start_json:]) if start_json >= 0 else {"id": tid, "runnerError": (p.stdout + p.stderr)[-2000:]}
        except subprocess.TimeoutExpired:
            kpi = {"id": tid, "runnerError": f"timeout after {a.timeout}s"}
        kpi["wallSeconds"] = time.time() - start
        with open(out / "results.jsonl", "a") as f: f.write(json.dumps(kpi, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"{tid}: phase={kpi.get('phase')} holdout={kpi.get('holdout')} proxySuccess={kpi.get('proxySuccess')} "
              f"{kpi['wallSeconds']:.0f}s", flush=True)

if __name__ == "__main__":
    main()
