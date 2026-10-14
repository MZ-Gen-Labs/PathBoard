#!/usr/bin/env python3
import pathlib, plistlib, subprocess, sys, tempfile
pkg = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="pathboard-pkg-check-") as scratch:
    expanded = pathlib.Path(scratch) / "expanded"
    subprocess.run(["pkgutil", "--expand-full", str(pkg), str(expanded)], check=True)
    infos = list(expanded.rglob("PathBoard.app/Contents/Info.plist"))
    assert len(infos) == 1, "Expected exactly one PathBoard app"
    info = plistlib.loads(infos[0].read_bytes())
    assert info["CFBundleIdentifier"] == "io.github.mz-gen-labs.PathBoard"
    assert info["LSMinimumSystemVersion"] == "27.0"
    binary = infos[0].parent / "MacOS/PathBoard"
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    assert arch == "arm64", arch
    assert (infos[0].parent / "Resources/LICENSE").exists()
    assert not list(expanded.rglob("Scripts")), "Installer scripts are not allowed"
    subprocess.run(["codesign", "--verify", "--strict", str(infos[0].parent.parent)], check=True)
print("PKG content check passed: arm64, app identity, minimum OS, LICENSE, ad-hoc signature, no installer scripts")
