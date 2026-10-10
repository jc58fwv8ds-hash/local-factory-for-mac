#!/usr/bin/env python3
"""Aggregate B.6 KPIs from <out>/results.jsonl (one measured run per task; nothing is re-run or dropped).

Definitions (Phase B plan): success = proxy success (tests passed in the run AND hidden holdout tests pass; the
completion contract additionally needs external requirement verification, which this proxy does not replace);
first pass = MODEL_FIRST_PASS_PASS; false success = tests passed but a holdout test failed (0 required).
Environment-invalid runs (inference health) are reported separately and excluded from model-quality rates."""
import json, statistics, sys
from collections import defaultdict
from pathlib import Path

def rate(n, d): return f"{n}/{d} ({100 * n / d:.0f}%)" if d else "0/0"

def main(out, suite_name="suite-b5"):
    rows = [json.loads(l) for l in (Path(out) / "results.jsonl").read_text().splitlines() if l.strip()]
    suite = {p.stem: json.loads(p.read_text()) for p in (Path(__file__).resolve().parent.parent / suite_name / "tasks").glob("*-*.json")}
    env = [r for r in rows if r.get("environmentClassification") == "ENVIRONMENT_INVALID" or "environmentInvalid" in str(r.get("runError", ""))]
    valid = [r for r in rows if r not in env and "runnerError" not in r]
    n = len(valid)
    usage = [r.get("modelUsage") or {} for r in valid]
    succ = [r for r in valid if r.get("proxySuccess")]
    report = {
        "tasksRun": len(rows), "environmentInvalid": len(env), "runnerErrors": sum(1 for r in rows if "runnerError" in r),
        "valid": n,
        "success": rate(len(succ), n),
        "testsPassed": rate(sum(1 for r in valid if r.get("testsPassed")), n),
        "falseSuccess": sum(1 for r in valid if r.get("falseSuccess")),
        "firstPass": rate(sum(1 for r in valid if r.get("modelFirstPass") == "MODEL_FIRST_PASS_PASS"), n),
        "firstPassAndSuccess": rate(sum(1 for r in succ if r.get("modelFirstPass") == "MODEL_FIRST_PASS_PASS"), n),
        "compilerRepair": rate(sum(1 for r in valid if r.get("modelCompilerRepair") == "MODEL_COMPILER_REPAIR_PASS"),
                               sum(1 for r in valid if str(r.get("modelCompilerRepair", "NOT_RUN")).startswith("MODEL_"))),
        "requirementReplan": rate(sum(1 for r in valid if r.get("modelRequirementReplan") == "MODEL_REQUIREMENT_REPLAN_PASS"),
                                  sum(1 for r in valid if str(r.get("modelRequirementReplan", "NOT_RUN")).startswith("MODEL_"))),
        "runtimeRepair": rate(sum(1 for r in valid if r.get("modelRuntimeRepair") == "MODEL_RUNTIME_REPAIR_PASS"),
                              sum(1 for r in valid if str(r.get("modelRuntimeRepair", "")).startswith("MODEL_"))),
        "timeToCorrectCompletionMedianSeconds": statistics.median([r["seconds"] for r in succ]) if succ else None,
        "secondsMedianAll": statistics.median([r["seconds"] for r in valid]) if valid else None,
        "modelCallsTotal": sum(u.get("calls", 0) for u in usage),
        "modelCallsMeanPerTask": (sum(u.get("calls", 0) for u in usage) / n) if n else None,
        "promptBytesTotal": sum(u.get("promptBytes", 0) for u in usage),
        "responseBytesTotal": sum(u.get("responseBytes", 0) for u in usage),
        "approxTokensTotal(bytes/2)": int(sum(u.get("promptBytes", 0) + u.get("responseBytes", 0) for u in usage) / 2),
        "modelSecondsTotal": sum(u.get("seconds", 0) for u in usage),
        "peakHarnessRSSBytes": max((r.get("memory", {}).get("harnessMaxRSSBytes", 0) for r in valid), default=0),
        "peakOllamaFootprintBytes": max((o.get("lifetimeMaxPhysFootprintBytes", 0) for r in valid
                                         for o in r.get("memory", {}).get("ollama", [])), default=0),
    }
    by = defaultdict(lambda: [0, 0])
    for r in valid:
        t = suite.get(r["id"], {})
        for key in [f"size:{t.get('size')}", f"category:{t.get('category')}", f"multiFile:{t.get('multiFile')}", f"unfamiliar:{t.get('unfamiliar')}"]:
            by[key][1] += 1; by[key][0] += bool(r.get("proxySuccess"))
    report["successBy"] = {k: rate(*v) for k, v in sorted(by.items())}
    report["failurePhases"] = dict(sorted(defaultdict(int, {}).items()))
    phases = defaultdict(int)
    for r in valid:
        if not r.get("proxySuccess"): phases[r.get("phase") or "none"] += 1
    report["failurePhases"] = dict(sorted(phases.items()))
    print(json.dumps(report, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "suite-b5")
