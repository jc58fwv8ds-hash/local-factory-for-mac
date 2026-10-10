#!/usr/bin/env python3
"""Validate the Phase B.5 task suite (see SUITE-SCHEMA.md).

Static:  python3 validate_suite.py [--only s-01]
Dynamic: python3 validate_suite.py --dynamic --candidate <harness checkout> [--only s-01]
Dynamic checks copy each variant into <candidate>/work/ and build + test it in the OS sandbox through
`<candidate>/.build/debug/HarnessKernelPilot --suite-check`. Exit status 0 and a final `OK` line mean valid.
"""
import argparse, difflib, json, os, re, shutil, subprocess, sys, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIZES = {"small": 6 * 1024, "medium": 20 * 1024, "large": 40 * 1024}
CATEGORIES = {"bugfix", "feature", "behaviour-change", "refactor-preserving", "multi-file feature", "unfamiliar-codebase"}
FIELDS = {"id", "objective", "size", "category", "multiFile", "unfamiliar", "initialFiles", "protectedTests",
          "maxEdits", "maxLines", "reference", "holdoutTests", "origin", "rationale"}
OPTIONAL = {"plausibleWrong"}
TEST_FUNC = re.compile(r"@Test(?:\([^)]*\))?\s+func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")


def is_test(path): return path.startswith("Tests/") and path.endswith(".swift")
def is_source(path): return path.startswith("Sources/") and path.endswith(".swift")


def regions(old, new):
    """(changed lines, contiguous edited regions) between two file contents."""
    ops = [op for op in difflib.SequenceMatcher(None, old.splitlines(), new.splitlines(), autojunk=False).get_opcodes() if op[0] != "equal"]
    lines = sum(max(i2 - i1, j2 - j1) for _, i1, i2, j1, j2 in ops)
    return lines, len(ops)


def static_check(task, errors):
    tid = task.get("id", "?")
    def e(msg): errors.append(f"{tid}: {msg}")
    missing = FIELDS - task.keys()
    extra = task.keys() - FIELDS - OPTIONAL
    if missing: e(f"missing fields {sorted(missing)}")
    if extra: e(f"unknown fields {sorted(extra)}")
    if missing: return
    if not re.fullmatch(r"s-\d{2}", task["id"]): e("id must be s-NN")
    if task["size"] not in SIZES: e("size")
    if task["category"] not in CATEGORIES: e(f"category must be one of {sorted(CATEGORIES)}")
    files, ref, hold = task["initialFiles"], task["reference"], task["holdoutTests"]
    wrong = task.get("plausibleWrong") or {}
    for name, d in [("initialFiles", files), ("reference", ref), ("holdoutTests", hold), ("plausibleWrong", wrong)]:
        if not isinstance(d, dict): e(f"{name} must be an object"); return
        for p, c in d.items():
            if p.startswith("/") or ".." in p.split("/") or not isinstance(c, str): e(f"{name}: bad path/content {p}")
            if "\r" in c: e(f"{name}: CRLF in {p}")
    pkg = files.get("Package.swift", "")
    if not pkg.startswith("// swift-tools-version: 6.0"): e("Package.swift must start with // swift-tools-version: 6.0")
    if re.search(r"unsafeFlags|\.package\(|resources:|plugins:|\.executableTarget|\.plugin\(", pkg): e("forbidden Package.swift feature")
    if not 1 <= pkg.count(".target(") <= 3 or pkg.count(".testTarget(") != 1: e("Package.swift: 1-3 .target and exactly one .testTarget")
    tests = [p for p in files if is_test(p)]
    test_dirs = {p.split("/")[1] for p in tests} | {p.split("/")[1] for p in hold}
    if len(test_dirs) != 1: e("all test files must be in one test target directory")
    if not task["protectedTests"] or not set(task["protectedTests"]) <= set(tests): e("protectedTests must be test files in initialFiles")
    if not hold or not all(is_test(p) and p not in files for p in hold): e("holdoutTests: new files under Tests/ only")
    names = []
    for p in tests + list(hold):
        src = files.get(p) or hold.get(p, "")
        if "import Testing" not in src or "XCTest" in src: e(f"{p}: Swift Testing only")
        names += TEST_FUNC.findall(src)
    if len(names) != len(set(names)): e("duplicate test function names")
    for p in set(files) - {"Package.swift"}:
        if not (is_source(p) or is_test(p)): e(f"unexpected file {p}")
    for name, d in [("reference", ref), ("plausibleWrong", wrong)]:
        for p in d:
            if p not in files or not is_source(p): e(f"{name} may only modify existing Sources/ files ({p})")
    if not ref: e("reference is empty")
    src_bytes = sum(len(c.encode()) for p, c in files.items() if is_source(p))
    if task["size"] in SIZES and src_bytes > SIZES[task["size"]]: e(f"Sources/ is {src_bytes} bytes, over {task['size']}")
    if task["multiFile"] != (len([p for p in ref if ref[p] != files.get(p)]) >= 2): e("multiFile must equal reference changing >= 2 files")
    lines = edits = 0
    for p, c in ref.items():
        if p in files:
            if c == files[p]: e(f"reference leaves {p} unchanged")
            dl, dr = regions(files[p], c); lines += dl; edits += dr
    if not (1 <= task["maxEdits"] <= 12 and 1 <= task["maxLines"] <= 200): e("maxEdits 1..12, maxLines 1..200")
    if edits > task["maxEdits"] or lines > task["maxLines"]: e(f"reference needs {edits} edits / {lines} lines, over limits")
    if edits and (task["maxEdits"] > 2 * max(edits, 2) or task["maxLines"] > 2 * max(lines, 10)): e("limits must keep <= 2x slack")
    obj = task["objective"]
    if not obj.strip() or not re.search(r"[぀-ヿ一-鿿]", obj): e("objective must be Japanese text")
    if "Tests/" in obj or any(n in obj for n in names): e("objective must not name test files or test functions")
    for p, c in ref.items():
        if p in files and len(c) > 200 and c in obj: e("objective pastes the solution")


def mix_check(tasks, errors):
    by = lambda k, v: sum(1 for t in tasks if t.get(k) == v)
    if len(tasks) < 30: errors.append(f"suite: {len(tasks)} tasks, need >= 30")
    for size, n in [("small", 8), ("medium", 10), ("large", 6)]:
        if by("size", size) < n: errors.append(f"suite: {by('size', size)} {size}, need >= {n}")
    if by("multiFile", True) < 10: errors.append("suite: need >= 10 multi-file tasks")
    if by("unfamiliar", True) < 5: errors.append("suite: need >= 5 unfamiliar tasks")
    if sum(1 for t in tasks if t.get("plausibleWrong")) < 10: errors.append("suite: need >= 10 tasks with plausibleWrong")
    if len({t.get("category") for t in tasks}) < 4: errors.append("suite: need >= 4 categories")
    ids = [t.get("id") for t in tasks]
    if len(ids) != len(set(ids)): errors.append("suite: duplicate ids")


def run_variant(candidate, task, overlay, label):
    work = candidate / "work" / f"b5v-{task['id']}-{label}-{uuid.uuid4().hex[:8]}"
    try:
        for p, c in {**task["initialFiles"], **overlay}.items():
            (work / p).parent.mkdir(parents=True, exist_ok=True)
            (work / p).write_text(c, encoding="utf-8")
        out = subprocess.run([str(candidate / ".build/debug/HarnessKernelPilot"), "--suite-check", str(candidate), str(work),
                              str(work.parent / (work.name + "-evidence"))], capture_output=True, text=True, timeout=600,
                             env={**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"})
        line = [l for l in out.stdout.splitlines() if l.startswith("{")]
        if not line: return None, (out.stdout + out.stderr)[-1500:]
        r = json.loads(line[-1])
        return (r["build"]["exit"] == 0, r.get("test", {}).get("exit") == 0), r.get("test", {}).get("output", "")[-1500:] or r["build"].get("output", "")[-1500:]
    finally:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(work.parent / (work.name + "-evidence"), ignore_errors=True)


def dynamic_check(candidate, task, errors):
    tid = task["id"]
    def expect(label, overlay, build, test):
        got, tail = run_variant(candidate, task, overlay, label)
        if got is None: errors.append(f"{tid} [{label}]: check did not run: {tail}"); return
        ok = got[0] == build and (test is None or got[1] == test)
        print(f"  {tid} {label:22} build={'ok' if got[0] else 'FAIL'} test={'ok' if got[1] else 'fail'} {'✓' if ok else '✗'}", flush=True)
        if not ok: errors.append(f"{tid} [{label}]: expected build={build} test={test}, got {got}\n{tail}")
    expect("initial", {}, True, False)
    expect("initial+holdout", task["holdoutTests"], True, False)
    expect("reference+holdout", {**task["reference"], **task["holdoutTests"]}, True, True)
    if task.get("plausibleWrong"):
        expect("wrong", task["plausibleWrong"], True, True)
        expect("wrong+holdout", {**task["plausibleWrong"], **task["holdoutTests"]}, True, False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dynamic", action="store_true")
    ap.add_argument("--candidate")
    ap.add_argument("--only")
    a = ap.parse_args()
    paths = sorted((HERE / "tasks").glob("s-*.json"))
    tasks, errors = [], []
    for p in paths:
        try: t = json.loads(p.read_text(encoding="utf-8"))
        except Exception as x: errors.append(f"{p.name}: invalid JSON {x}"); continue
        if t.get("id") != p.stem: errors.append(f"{p.name}: id must match file name")
        tasks.append(t)
    selected = [t for t in tasks if not a.only or t.get("id") == a.only]
    for t in selected: static_check(t, errors)
    # 見本は3件だけなので課題の配分の検査はしない
    if a.dynamic and not errors:
        if not a.candidate: sys.exit("--dynamic needs --candidate")
        candidate = Path(a.candidate).resolve()
        for t in selected: dynamic_check(candidate, t, errors)
    for x in errors: print("ERROR", x)
    print("OK" if not errors else f"{len(errors)} error(s)")
    sys.exit(0 if not errors else 1)


if __name__ == "__main__":
    main()
