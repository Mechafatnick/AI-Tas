#!/usr/bin/env python3
"""Verify that the checked-in Quartus project has no external source dependency."""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
QIP = ROOT / "files.qip"
QSF = ROOT / "TaitoAir.qsf"

errors: list[str] = []

for path in (QIP, QSF):
    if not path.is_file():
        errors.append(f"missing required project file: {path.relative_to(ROOT)}")
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    for token in ("http://", "https://", "git clone", "git submodule", "raw.githubusercontent.com"):
        if token in text:
            errors.append(f"external dependency marker '{token}' found in {path.relative_to(ROOT)}")

if QIP.is_file():
    for match in re.finditer(r"(?:SYSTEMVERILOG_FILE|VERILOG_FILE|QIP_FILE)\s+([^\s]+)", QIP.read_text(encoding="utf-8")):
        rel = match.group(1).strip('"')
        candidate = ROOT / rel
        if not candidate.exists():
            errors.append(f"missing local Quartus source: {rel}")

# The repository itself must not rely on a submodule checkout.
if (ROOT / ".gitmodules").exists():
    errors.append(".gitmodules exists; this repository must be source-complete")

# Require the bundled JT12/TV80 source trees referenced by files.qip.
for required in (
    ROOT / "rtl/third_party/jt12/target/quartus/jt10.qip",
    ROOT / "rtl/third_party/tv80/tv80s.v",
    ROOT / "rtl/cpu/fx68k/fx68k.sv",
    ROOT / "rtl/cpu/tms320c25/tas_tms320c25.sv",
    ROOT / "sys/sys.tcl",
    ROOT / "sys/sys_analog.tcl",
):
    if not required.exists():
        errors.append(f"missing bundled dependency: {required.relative_to(ROOT)}")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)

print("PASS: Quartus project is self-contained; all referenced sources are local.")
