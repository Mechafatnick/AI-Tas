#!/usr/bin/env python3
"""Build the linear MiSTer ROM image for a Taito Air System game.

    build_rom.py [--game topland|toplandj|ainferno|ainfernou|ainfernoj] SOURCE_DIR OUTPUT.rom

SOURCE_DIR holds the unzipped MAME set (for a clone, the parent's files plus
the clone's own). The layout matches the MRAs in
releases/; the image is only used by the simulations."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA1 = {
    # Air Inferno (World / US / Japan)
    "c45_22.43": "9c2a60282d3f9f115b94cb5b6d64bbfc9d726d1d",
    "c45_20.14": "002013c02b546d3f5a9f3a3149971975a73cc8ce",
    "c45_21.42": "309e42f79cbd48ceae58a15afb648aef838822f0",
    "c45_29.13": "b02805d934b4b7dcfb4fa48bd707a1b81ccb40cf",
    "c45_28.13": "cf1f163ec252e9986132095f22bca8d061bfdf9a",
    "c45_19.ic13": "7b436ba60628a410a5053095dafaee0bd7932daf",
    "c45-23.34": "63232c2acef86e8c8ffaad36ab0b6c4cc1eb48f8",
    "c45-25.35": "542aa6e2af510aea00db40bf803cb6653d4e7747",
    "c45-24.6": "817769d21583f5281ba044ce8c134c9239d1e83e",
    "c45-11.28": "69d570efa8146fb0a712ff45e77bda6fd85769f8",
    "c45-12.29": "2bbb981853a7abbba90afb8eb58f6869357551d3",
    "c45-13.30": "13c035e84affa59734c6dd1b07963c08654b5f5a",
    "c45-14.31": "0b047e805663b144dc2388c86438950fcdc29658",
    "c45-15.40": "5de519a23300d5b3b09ce7cf8c02a1a6b2fb985c",
    "c45-16.41": "d0b1adfce5c1f4e21c5d84527d22ace14578f2d7",
    "c45-17.42": "41073d5cf20df12d5ba1c424c9d9f0b2d9836d5d",
    "c45-18.43": "dd073b7bfbf2f88432337027ae9fb6c4f02a538f",
    "c45-01.5": "3aa8b4f759a1c196de39754a9ccdf4fabdbab388",
    "c45-02.4": "6a635671fa2518f74015429ce580d7b7f00299ad",
    "c45-03.3": "a53d5ba01825f825e31a014cb4808f59ef86f0c9",
    "c45-04.2": "2d98bde55621762509dfc645d9ca5e267b1757ae",
    "c45-05.1": "6264bbe4d7ad3070c6441859eb704a42910a82f0",
    "c45-06.31": "a465f9bb874b1eff08742b33cc3c364703b281ca",
    "c45-30.9": "91c34a53d2fec619f2536ca79fdc6a17fb0d21e4",
    # Top Landing (World)
    "b09_37.13": "b960208e63cede116925e064279a6cf107aef81c",
    "b62-13.1": "198d4f828132316c624da998e49b1873b9886bf0",
    "b62-14.2": "4660570fa6263c28cfae7ccdf154763cc6144896",
    "b62-15.3": "f35afdd7cfd4c09907fb062beb5ae46c2286a381",
    "b62-16.4": "f6fc9322dea8d82bfec3be3fdc8616dc6adf666e",
    "b62-17.5": "91c8cc4e99534b2d533895a342abb22766a20090",
    "b62-18.31": "43f07fe19dec351e851defdf9c7810fb9df04736",
    "b62-20.6": "7593a327f4ea0cc9e28fd3269278871f62fb0598",
    "b62-21.35": "0593718d15b30b10f7686959932e2c934de2a529",
    "b62-28.22": "2c07a0e71d11bca67427331217c507d849500ec1",
    "b62-29.27": "6df3e9782946cf6f4a21ee3d335548c53cd21e3a",
    "b62-30.28": "6bc777bdf1a56952dbfbe2f595279a43e2fa98fd",
    "b62-31.29": "5b014d7d6fa1daf400ac1a437f551281debfdba6",
    "b62-32.30": "d8e0c37b5227d8583d523164ffc6828b4508d5a3",
    "b62-33.39": "7292e3fa69cad6494f2e8e7efa9c3f989bdf958d",
    "b62-34.40": "862c23c095f96f9e0cae00d70947782d5f4e45e6",
    "b62-35.47": "5305c84abcbcc23281744454803b849853b26632",
    "b62-36.48": "eb0dc5d0a6f875e3b8335fb30d4c2ad3880c31b9",
    "b62-42.34": "3a336987aad7bf4df658f924de4bbe6f0fff6d59",
    # Top Landing (Japan)
    "b62_27.ic43": "b5bee250dc4ba530b1d3a73926dc848a0f340a70",
    "b62_26.ic14": "b5df3dc43ed299a22213b517ac4a1c1d776bbdbf",
    "b62_19.ic34": "58dc4a18d1d1b0d023721677a9c1b091a6304f4a",
    "b62_22.12": "8518d8e722d4f2516f75224d9a21ab20d8ee6c78",
    "b62_23.41": "0840668dda48f4c9a85410361bfba3ae9580a71f",
    "b62_24.13": "ab8d8f5f6597bfcde4e9ccf9e0181b8b6e769ada",
    "b62_25.42": "ada679198739cd6a419d3fa4311bb92dc385099c",
    "b62_40.14": "6932c62d8051b1811c30139dbd0375115305c731",
    "b62_41.43": "72e4441ad468f37cff69c36699867119ad28274c",
}

OFFSETS = {
    "main": 0x000000,
    "audio": 0x0C0000,
    "dsp": 0x0D0000,
    "gfx": 0x100000,
    "adpcma": 0x200000,
    "adpcmb": 0x2A0000,
    "mecha": 0x2C0000,
    "user1": 0x2C8000,
    "end": 0x2CA000,
}


def checked_read(directory: Path, name: str) -> bytes:
    path = directory / name
    data = path.read_bytes()
    actual = hashlib.sha1(data).hexdigest()
    expected = EXPECTED_SHA1[name]
    if actual != expected:
        raise SystemExit(f"SHA1 mismatch for {path}: {actual}, expected {expected}")
    return data


def interleave(even: bytes, odd: bytes) -> bytes:
    if len(even) != len(odd):
        raise SystemExit("Interleaved ROM halves have different sizes")
    result = bytearray(len(even) * 2)
    result[0::2] = even
    result[1::2] = odd
    return bytes(result)


GAMES = {
    "topland": {
        "main_pairs": (
            ("b62_41.43", "b62_40.14"),
            ("b62_25.42", "b62_24.13"),
            ("b62_23.41", "b62_22.12"),
        ),
        "audio": "b62-42.34",
        "dsp": ("b62-21.35", "b62-20.6"),
        # lane n is MAME's ROM_LOAD64_BYTE offset n
        "gfx_lanes": (
            "b62-32.30", "b62-31.29", "b62-30.28", "b62-35.47",
            "b62-34.40", "b62-29.27", "b62-36.48", "b62-33.39",
        ),
        "adpcma": ("b62-17.5", "b62-16.4", "b62-15.3", "b62-14.2", "b62-13.1"),
        "adpcmb": "b62-18.31",
        "mecha": "b09_37.13",
        "user1": "b62-28.22",
    },
    "ainferno": {
        "main_pairs": (
            ("c45_22.43", "c45_20.14"),
            ("c45_21.42", "c45_29.13"),
        ),
        "audio": "c45-23.34",
        "dsp": ("c45-25.35", "c45-24.6"),
        "gfx_lanes": (
            "c45-18.43", "c45-14.31", "c45-17.42", "c45-13.30",
            "c45-16.41", "c45-12.29", "c45-15.40", "c45-11.28",
        ),
        "adpcma": ("c45-01.5", "c45-02.4", "c45-03.3", "c45-04.2", "c45-05.1"),
        "adpcmb": "c45-06.31",
        # The mecha (controller board) program is not run by the core; its
        # upper half is blank on the 27C512, so the 32K slot holds it.
        "mecha": "c45-30.9",
        "user1": None,
    },
}
GAMES["toplandj"] = dict(GAMES["topland"], main_pairs=(
    ("b62_27.ic43", "b62_26.ic14"),) + GAMES["topland"]["main_pairs"][1:],
    audio="b62_19.ic34")
GAMES["ainfernou"] = dict(GAMES["ainferno"], main_pairs=(
    ("c45_22.43", "c45_20.14"), ("c45_21.42", "c45_28.13")))
GAMES["ainfernoj"] = dict(GAMES["ainferno"], main_pairs=(
    ("c45_22.43", "c45_20.14"), ("c45_21.42", "c45_19.ic13")))


def build(source: Path, game: str = "topland") -> bytes:
    layout = GAMES[game]
    image = bytearray([0xFF]) * OFFSETS["end"]

    main = b"".join(
        interleave(checked_read(source, even), checked_read(source, odd))
        for even, odd in layout["main_pairs"]
    )
    image[OFFSETS["main"] : OFFSETS["main"] + len(main)] = main

    audio = checked_read(source, layout["audio"])
    image[OFFSETS["audio"] : OFFSETS["audio"] + len(audio)] = audio

    dsp_even = checked_read(source, layout["dsp"][0])
    dsp_odd = checked_read(source, layout["dsp"][1])
    # The fitted C25 program space is 4K words.  Both physical 8 KiB ROMs in
    # each supported set contain 0xff in their upper 4 KiB, so the meaningful
    # pair is exactly 0x2000 interleaved bytes.  Fail closed if another
    # dump/set ever violates that board-image assumption instead of silently
    # truncating executable program data when the streamed sidecar is written.
    if any(value != 0xFF for value in dsp_even[0x1000:]) or any(
        value != 0xFF for value in dsp_odd[0x1000:]
    ):
        raise SystemExit("DSP ROM upper halves are not blank; 4K-word program RAM is insufficient")
    dsp = interleave(dsp_even[:0x1000], dsp_odd[:0x1000])
    image[OFFSETS["dsp"] : OFFSETS["dsp"] + len(dsp)] = dsp

    # Eight ROMs are connected as byte lanes of the TC0080VCO graphics bus.
    gfx = bytearray(0x100000)
    for lane, name in enumerate(layout["gfx_lanes"]):
        gfx[lane::8] = checked_read(source, name)
    image[OFFSETS["gfx"] : OFFSETS["gfx"] + len(gfx)] = gfx

    adpcma = b"".join(checked_read(source, name) for name in layout["adpcma"])
    image[OFFSETS["adpcma"] : OFFSETS["adpcma"] + len(adpcma)] = adpcma

    adpcmb = checked_read(source, layout["adpcmb"])
    image[OFFSETS["adpcmb"] : OFFSETS["adpcmb"] + len(adpcmb)] = adpcmb

    mecha = checked_read(source, layout["mecha"])[: OFFSETS["user1"] - OFFSETS["mecha"]]
    image[OFFSETS["mecha"] : OFFSETS["mecha"] + len(mecha)] = mecha

    if layout["user1"]:
        user1 = checked_read(source, layout["user1"])
        image[OFFSETS["user1"] : OFFSETS["user1"] + len(user1)] = user1
    return bytes(image)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game", choices=sorted(GAMES), default="topland")
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    source = args.source or Path("roms") / args.game
    output = args.output or Path("roms") / f"{args.game}.rom"
    image = build(source, args.game)
    args.output = output
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    dsp_output = args.output.with_name(f"{args.output.stem}_dsp.bin")
    dsp_image = image[OFFSETS["dsp"] : OFFSETS["dsp"] + 0x2000]
    dsp_output.write_bytes(dsp_image)
    print(
        f"wrote {args.output} ({len(image):#x} bytes, "
        f"sha1 {hashlib.sha1(image).hexdigest()})"
    )
    print(
        f"wrote {dsp_output} ({len(dsp_image):#x} bytes, "
        f"md5 {hashlib.md5(dsp_image).hexdigest()})"
    )


if __name__ == "__main__":
    main()
