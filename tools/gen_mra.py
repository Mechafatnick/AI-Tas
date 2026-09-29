#!/usr/bin/env python3
"""Write the MRAs into releases/: Top Landing (World, Japan) and Air Inferno
(World, US, Japan), one per MAME set.

The DDR image (ioctl index 0) has the same layout as tools/build_rom.py; the
C25 program is streamed again at index 1 and index 2 carries the game-select
byte (0 = Top Landing, 1 = Air Inferno). DIP switches and inputs follow MAME's
topland and ainferno ports. A clone's MRA looks in its own zip, then in the
parent's (MAME split or merged sets both work).
"""
from pathlib import Path

# Top Landing: the sets differ in the first pair of 68000 ROMs and the Z80
# program.  setname: (region, manufacturer, (even, crc), (odd, crc), (audio, crc))
TOPLAND = {
    "topland": ("World", "Taito Corporation Japan", ("b62_41.43", "28264798"),
                ("b62_40.14", "db872f7d"), ("b62-42.34", "389230e0")),
    "toplandj": ("Japan", "Taito Corporation", ("b62_27.ic43", "c717c3b7"),
                 ("b62_26.ic14", "340bfa56"), ("b62_19.ic34", "2c0a3786")),
}

TOPLAND_TEMPLATE = """<misterromdescription>
    <rotation>horizontal</rotation>
    <name>Top Landing ({region})</name>
    <setname>{setname}</setname>
    <year>1988</year>
    <manufacturer>{manufacturer}</manufacturer>
    <players>1</players>
    <rbf>TaitoAir</rbf>
    <joystick>analog</joystick>
    <region>{region}</region>
    <!-- Assemble the DDR image directly from the unmodified MAME set. -->
    <rom index="0" zip="{zips}" address="0x30000000" md5="none">
        <interleave output="16">
            <part name="{even}" crc="{even_crc}" map="01"/>
            <part name="{odd}" crc="{odd_crc}" map="10"/>
        </interleave>
        <interleave output="16">
            <part name="b62_25.42" crc="1bd53a72" map="01"/>
            <part name="b62_24.13" crc="845026c5" map="10"/>
        </interleave>
        <interleave output="16">
            <part name="b62_23.41" crc="ef3a971c" map="01"/>
            <part name="b62_22.12" crc="94279201" map="10"/>
        </interleave>

        <part name="{audio}" crc="{audio_crc}"/>

        <interleave output="16">
            <part name="b62-21.35" crc="5f38460d" offset="0x0000" length="0x1000" map="01"/>
            <part name="b62-20.6"  crc="a4afe958" offset="0x0000" length="0x1000" map="10"/>
        </interleave>
        <part repeat="0x2e000">FF</part>

        <interleave output="64">
            <part name="b62-32.30" crc="66806646" map="00000001"/>
            <part name="b62-31.29" crc="3feebfe3" map="00000010"/>
            <part name="b62-30.28" crc="30e37cb8" map="00000100"/>
            <part name="b62-35.47" crc="cba7bac5" map="00001000"/>
            <part name="b62-34.40" crc="a7e10ca4" map="00010000"/>
            <part name="b62-29.27" crc="efdd5c51" map="00100000"/>
            <part name="b62-36.48" crc="4259e76a" map="01000000"/>
            <part name="b62-33.39" crc="38786867" map="10000000"/>
        </interleave>

        <part name="b62-17.5"  crc="36447066"/>
        <part name="b62-16.4"  crc="203a5c27"/>
        <part name="b62-15.3"  crc="e35ffe81"/>
        <part name="b62-14.2"  crc="617948a3"/>
        <part name="b62-13.1"  crc="b37dc3ea"/>
        <part name="b62-18.31" crc="3a4e687a"/>
        <part name="b09_37.13" crc="4bdf15ed"/>
        <part name="b62-28.22" crc="c4be68a6"/>
    </rom>
    <!-- The C25 program is also streamed through ioctl index 1. -->
    <rom index="1" zip="{zips}" md5="none">
        <interleave output="16">
            <part name="b62-21.35" crc="5f38460d" offset="0x0000" length="0x1000" map="01"/>
            <part name="b62-20.6"  crc="a4afe958" offset="0x0000" length="0x1000" map="10"/>
        </interleave>
    </rom>
    <!-- Game select [AI-8]: 0 = Top Landing. -->
    <rom index="2" md5="none">
        <part>00</part>
    </rom>
    <buttons names="Start,Coin,Throttle Up,Throttle Down"
             default="Start,Select,-,-" count="1"/>
    <!-- Buttons [AI-11]. Test mode (SWA:3) is the core's Service mode OSD
         option. -->
    <switches default="FF,FF" base="8">
        <dip bits="3" name="Demo Sounds" ids="Off,On"/>
        <dip bits="4,5" name="Coin A" ids="4 Coins/1 Play,3 Coins/1 Play,2 Coins/1 Play,1 Coin/1 Play"/>
        <dip bits="6,7" name="Coin B" ids="1 Coin/6 Plays,1 Coin/4 Plays,1 Coin/3 Plays,1 Coin/2 Plays"/>
        <dip bits="8,9" name="Difficulty" ids="Hardest,Hard,Easy,Medium"/>
    </switches>
</misterromdescription>
"""

# Air Inferno: the sets differ in one 68000 ROM.
MAIN_ODD = {
    "ainferno": ("c45_29.13", "b0ca15f1", "World", "Taito Corporation Japan", "ainferno"),
    "ainfernou": ("c45_28.13", "c7cd2567", "US", "Taito America Corporation", "ainfernou"),
    "ainfernoj": ("c45_19.ic13", "5ec474dd", "Japan", "Taito Corporation Japan", "ainfernoj"),
}

TEMPLATE = """<misterromdescription>
    <rotation>horizontal</rotation>
    <name>Air Inferno ({region})</name>
    <setname>{setname}</setname>
    <year>1990</year>
    <manufacturer>{manufacturer}</manufacturer>
    <players>1</players>
    <rbf>TaitoAir</rbf>
    <joystick>analog</joystick>
    <region>{region}</region>
    <!-- Assemble the DDR image directly from the unmodified MAME set. -->
    <rom index="0" zip="{zips}" address="0x30000000" md5="none">
        <interleave output="16">
            <part name="c45_22.43" crc="50300926" map="01"/>
            <part name="c45_20.14" crc="39b189d9" map="10"/>
        </interleave>
        <interleave output="16">
            <part name="c45_21.42" crc="1b687241" map="01"/>
            <part name="{odd}" crc="{odd_crc}" map="10"/>
        </interleave>
        <!-- 0x80000-0xbffff is empty on this board -->
        <part repeat="0x40000">FF</part>

        <part name="c45-23.34" crc="d0750c78"/>

        <interleave output="16">
            <part name="c45-25.35" crc="c0d39f95" offset="0x0000" length="0x1000" map="01"/>
            <part name="c45-24.6"  crc="1013d937" offset="0x0000" length="0x1000" map="10"/>
        </interleave>
        <part repeat="0x2e000">FF</part>

        <interleave output="64">
            <part name="c45-18.43" crc="ba7ecf3b" map="00000001"/>
            <part name="c45-14.31" crc="481b6f29" map="00000010"/>
            <part name="c45-17.42" crc="0dbee000" map="00000100"/>
            <part name="c45-13.30" crc="69b82af6" map="00001000"/>
            <part name="c45-16.41" crc="c6eb93b0" map="00010000"/>
            <part name="c45-12.29" crc="4ae305b8" map="00100000"/>
            <part name="c45-15.40" crc="d4610698" map="01000000"/>
            <part name="c45-11.28" crc="d9b4b77c" map="10000000"/>
        </interleave>

        <part name="c45-01.5"  crc="052997b2"/>
        <part name="c45-02.4"  crc="2fc0a88e"/>
        <part name="c45-03.3"  crc="0e1e5b5f"/>
        <part name="c45-04.2"  crc="6d081044"/>
        <part name="c45-05.1"  crc="6c59a808"/>
        <part name="c45-06.31" crc="6a7976d4"/>
        <part name="c45-30.9"  crc="fa2db40f" length="0x8000"/>
        <part repeat="0x2000">FF</part>
    </rom>
    <!-- The C25 program is also streamed through ioctl index 1. -->
    <rom index="1" zip="{zips}" md5="none">
        <interleave output="16">
            <part name="c45-25.35" crc="c0d39f95" offset="0x0000" length="0x1000" map="01"/>
            <part name="c45-24.6"  crc="1013d937" offset="0x0000" length="0x1000" map="10"/>
        </interleave>
    </rom>
    <!-- Game select [AI-8]: 1 = Air Inferno. -->
    <rom index="2" md5="none">
        <part>01</part>
    </rom>
    <buttons names="Start,Coin,Throttle Up,Throttle Down,Fire,Lever,Pedal L,Pedal R,Handle X,Handle Y"
             default="Start,Select,-,-,A,B,L,R,-,-" count="1"/>
    <!-- Buttons [AI-9], [AI-11]. Test mode (SWA:3) is the core's Service
         mode OSD option. The rudder pedals default to fitted so that the
         Pedal L/R buttons act. -->
    <switches default="FF,EF" base="8">
        <dip bits="0" name="Moving Control" ids="DX Moving Only,Upright/Cockpit"/>
        <dip bits="1" name="Motion Test Mode" ids="On,Off"/>
        <dip bits="3" name="Demo Sounds" ids="Off,On"/>
        <dip bits="4,5" name="Coinage" ids="4 Coins/1 Credit,3 Coins/1 Credit,2 Coins/1 Credit,1 Coin/1 Credit"/>
        <dip bits="6,7" name="Price to Continue" ids="3 Coins/1 Credit,2 Coins/1 Credit,1 Coin/1 Credit,Same as Start"/>
        <dip bits="8,9" name="Difficulty" ids="Hardest,Hard,Easy,Medium"/>
        <dip bits="10,11" name="Timer Length" ids="Hardest,Hard,Easy,Medium"/>
        <dip bits="12" name="Rudder Pedal" ids="With (Cockpit/DX),Without (Upright)"/>
    </switches>
</misterromdescription>
"""


def clone_zips(setname, parent):
    return f"{parent}.zip" if setname == parent else f"{setname}.zip|{parent}.zip"


def main():
    out = Path(__file__).resolve().parent.parent / "releases"
    for setname, (region, manufacturer, even, odd, audio) in TOPLAND.items():
        text = TOPLAND_TEMPLATE.format(
            region=region, setname=setname, manufacturer=manufacturer,
            zips=clone_zips(setname, "topland"), even=even[0], even_crc=even[1],
            odd=odd[0], odd_crc=odd[1], audio=audio[0], audio_crc=audio[1])
        path = out / f"Top Landing ({region}).mra"
        path.write_text(text)
        print("wrote", path)
    for setname, (odd, crc, region, manufacturer, _) in MAIN_ODD.items():
        text = TEMPLATE.format(region=region, setname=setname, manufacturer=manufacturer,
                               zips=clone_zips(setname, "ainferno"), odd=odd, odd_crc=crc)
        path = out / f"Air Inferno ({region}).mra"
        path.write_text(text)
        print("wrote", path)


if __name__ == "__main__":
    main()
