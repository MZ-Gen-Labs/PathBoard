#!/usr/bin/env python3
import hashlib, json, pathlib, subprocess, sys
paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
excluded = {"docs/release-gate.json", "docs/implementation-status.md"}
hash_value = hashlib.sha256()
for name in sorted(p for p in paths if p and p not in excluded and not p.startswith("docs/acceptance-results/")):
    hash_value.update(name.encode() + b"\0" + pathlib.Path(name).read_bytes() + b"\0")
fingerprint = hash_value.hexdigest()
if "--fingerprint" in sys.argv:
    print(fingerprint)
    sys.exit(0)
record = json.loads(pathlib.Path("docs/release-gate.json").read_text())
assert record.get("tested_fingerprint") == fingerprint, "Acceptance must cover the exact release source fingerprint"
assert record.get("p0_p1_passed") is True, "Manual P0/P1 acceptance is incomplete"
assert record.get("cloud_matrix_passed") is True, "Cloud-device matrix is incomplete"
assert record.get("second_mac_pkg_passed") is True, "Second-Mac PKG acceptance is incomplete"
assert record.get("evidence"), "Acceptance evidence is required"
print("Release gate passed")
