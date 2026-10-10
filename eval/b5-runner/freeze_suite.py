#!/usr/bin/env python3
"""Freeze a suite: SHA-256 of the schema, validator and every task file -> ../<suite>/SUITE-FREEZE.json.
`python3 freeze_suite.py [suite-b5|suite-c1]` (default suite-b5). Refuses to overwrite an existing freeze.
Run only after static and dynamic validation printed OK."""
import hashlib, json, sys, datetime
from pathlib import Path

EVAL = Path(__file__).resolve().parent.parent
SUITE = EVAL / "suite-b5"

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def manifest(suite=SUITE):
    files = [suite / "SUITE-SCHEMA.md", suite / "validate_suite.py"] + sorted((suite / "tasks").glob("*-*.json"))
    return {str(p.relative_to(suite)): digest(p) for p in files}

if __name__ == "__main__":
    suite = EVAL / (sys.argv[1] if len(sys.argv) > 1 else "suite-b5")
    out = suite / "SUITE-FREEZE.json"
    if out.exists(): sys.exit("already frozen: " + str(out))
    m = manifest(suite)
    body = {"frozenAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "taskCount": sum(1 for k in m if k.startswith("tasks/")), "files": m}
    out.write_text(json.dumps(body, indent=2, sort_keys=True) + "\n")
    print(f"frozen {body['taskCount']} tasks; manifest sha256 {hashlib.sha256(out.read_bytes()).hexdigest()}")
