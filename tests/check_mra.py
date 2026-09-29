#!/usr/bin/env python3
"""Assemble an MRA's ROM entries the way MiSTer's loader does (the subset the
Taito Air MRAs use) and compare index 0 with tools/build_rom.py's image and
index 1 with its DSP sidecar.

    check_mra.py MRA ROM_DIR GAME
ROM_DIR holds the unzipped files of the set (and its parent)."""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import build_rom  # noqa: E402


def part_bytes(part, roms):
    if part.get("name") is None:
        data = bytes.fromhex("".join(part.text.split()))
        return data * int(part.get("repeat", "1"), 0)
    data = (roms / part.get("name")).read_bytes()
    offset = int(part.get("offset", "0"), 0)
    length = int(part.get("length", str(len(data) - offset)), 0)
    return data[offset:offset + length]


def interleave(node, roms):
    width = int(node.get("output")) // 8
    parts = [(part_bytes(p, roms), p.get("map")) for p in node.findall("part")]
    words = len(parts[0][0]) // sum(1 for c in parts[0][1] if c != "0")
    out = bytearray(words * width)
    for data, mapping in parts:
        taken = sum(1 for c in mapping if c != "0")
        for pos, ch in enumerate(reversed(mapping)):   # rightmost = output byte 0
            if ch == "0":
                continue
            src = int(ch) - 1
            out[pos::width] = data[src::taken][:words]
    return bytes(out)


def assemble(rom, roms):
    out = bytearray()
    for node in rom:
        if node.tag == "part":
            out += part_bytes(node, roms)
        elif node.tag == "interleave":
            out += interleave(node, roms)
    return bytes(out)


def main():
    mra, roms, game = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    root = ET.parse(mra).getroot()
    entries = {int(r.get("index")): assemble(r, roms) for r in root.findall("rom")}
    image = build_rom.build(roms, game)
    dsp = image[build_rom.OFFSETS["dsp"]:build_rom.OFFSETS["dsp"] + 0x2000]
    ok = True
    if entries[0] != image:
        ok = False
        print("index 0 differs: %d vs %d bytes" % (len(entries[0]), len(image)))
        for i, (a, b) in enumerate(zip(entries[0], image)):
            if a != b:
                print("  first difference at %06x" % i)
                break
    if entries[1] != dsp:
        ok = False
        print("index 1 differs from the DSP program")
    want = 1 if game.startswith("ainferno") else 0
    if entries.get(2, b"\x00") != bytes([want]):
        ok = False
        print("index 2 (game select) is %r, want %d" % (entries.get(2), want))
    print(("PASS" if ok else "FAIL"), mra.name)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
