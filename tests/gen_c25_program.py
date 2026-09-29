#!/usr/bin/env python3
"""Random TMS320C25 programs for tests/tb_c25_diff.sv.

Writes a program (hex words for $readmemh) and a 64K-word data image. The
programs only use instructions both tas_tms320c25 and the reference core
implement, and always terminate in a branch-to-self:

  * straight-line code with every addressing mode (direct, and indirect with
    all the AR modifications and ARP changes) against both on-chip RAM
    (0000-03FF) and board RAM, so both of the new core's data paths are hit;
  * forward conditional branches, BACC/CALA through computed targets,
    CALL/RET to leaf subroutines;
  * RPTK/RPT repeating single-word instructions and BLKD;
  * BANZ loops whose bodies leave the loop counter AR7 alone;
  * PUSH/POP/PSHD at the top level only (subroutine returns stay intact).

usage: gen_c25_program.py SEED PROG.hex DATA.hex   (prints the end address)
"""
import random
import sys

PROG_WORDS = 4096


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.code = []          # items: int word, or ('label', name) placeholder
        self.labels = {}
        self.fixups = []        # (index, label)
        self.nlabel = 0

    # ---- emission -------------------------------------------------------
    def emit(self, *words):
        for w in words:
            self.code.append(w & 0xFFFF)

    def emit_ref(self, label):
        self.fixups.append((len(self.code), label))
        self.code.append(0)

    def new_label(self):
        self.nlabel += 1
        return "L%d" % self.nlabel

    def place(self, label):
        self.labels[label] = len(self.code)

    # ---- operands -----------------------------------------------------------
    def indirect(self, allow_ar7=True):
        """Indirect addressing byte. With allow_ar7 False the next-ARP field
        never selects AR7 (the caller also keeps ARP off 7)."""
        r = self.r
        mode = r.choice([0, 1, 2, 4, 5, 6, 7])
        low = 0x80 | (mode << 4)
        if r.random() < 0.4:
            nar = r.randrange(7 if not allow_ar7 else 8)
            low |= 0x08 | nar
        return low

    def direct(self):
        return self.r.randrange(0x80)

    def mem(self, allow_ar7=True):
        return self.indirect(allow_ar7) if self.r.random() < 0.6 else self.direct()

    def pointer(self):
        r = self.r
        x = r.random()
        if x < 0.45:
            return r.randrange(0x000, 0x400)        # on-chip RAM
        if x < 0.8:
            return 0x8000 + r.randrange(0x100)      # board RAM
        return r.randrange(0x400, 0x10000)          # anywhere external

    # ---- instruction pools -------------------------------------------------------
    READ_OPS = (
        list(range(0x00, 0x30)) +                   # ADD SUB LAC with shift
        list(range(0x30, 0x38)) +                   # LAR
        list(range(0x38, 0x3F)) +                   # MPY SQRA MPYA MPYS LT LTA LTP
        [0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
         0x48, 0x49, 0x4A, 0x4C, 0x4D, 0x4E, 0x4F] +
        [0x52, 0x53, 0x57, 0x5A, 0x5B] +
        list(range(0x90, 0xA0)) +                   # BIT
        [0xCF]                                      # MPYU
    )
    WRITE_OPS = list(range(0x60, 0x78)) + [0x7C, 0x7D]
    CE_OPS = [0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
              0x14, 0x15, 0x16, 0x18, 0x19, 0x1B, 0x23, 0x27,
              0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x50, 0x51, 0x52, 0x53]

    def one_word(self, ctx):
        """A single-word, non-flow instruction. ctx: dict with
        'stack' (PUSH/POP/PSHD allowed), 'no_ar7' (keep AR7 and ARP 7 out)."""
        r = self.r
        no_ar7 = ctx.get('no_ar7', False)
        while True:
            k = r.random()
            if k < 0.45:
                op = r.choice(self.READ_OPS)
                if op == 0x52 and r.random() < 0.7:
                    continue                        # LDP scatters DP: keep it rare
                if no_ar7 and op == 0x37:
                    continue
                if op == 0x54 and not ctx.get('stack'):
                    continue
                return (op << 8) | self.mem(not no_ar7)
            if k < 0.52 and ctx.get('stack'):
                return (0x54 << 8) | self.mem(not no_ar7)          # PSHD
            if k < 0.72:
                op = r.choice(self.WRITE_OPS)
                return (op << 8) | self.mem(not no_ar7)
            if k < 0.80:
                c = r.choice(self.CE_OPS + ([0x1C, 0x1D] if ctx.get('stack') else []))
                return 0xCE00 | c
            j = r.randrange(9)
            if j == 0:                                  # MAR / LARP
                if r.random() < 0.5:
                    return 0x5500 | self.indirect(not no_ar7)
                return 0x5588 | r.randrange(7 if no_ar7 else 8)
            if j == 1 and not no_ar7:                   # ADRK / SBRK (ARP is never 7 in no_ar7 bodies... keep simple)
                return (r.choice([0x7E, 0x7F]) << 8) | r.randrange(256)
            if j == 1:
                continue
            if j == 2:                                  # MPYK
                return 0xA000 | r.randrange(0x2000)
            if j == 3:                                  # LARK
                a = r.randrange(7 if no_ar7 else 8)
                return 0xC000 | (a << 8) | r.randrange(256)
            if j == 4:                                  # LDPK
                return 0xC800 | r.choice([0, 4, 5, 6, 7, 0x100, 0x101, r.randrange(512)])
            if j == 5:                                  # LACK
                return 0xCA00 | r.randrange(256)
            if j in (6, 7):                             # ADDK / SUBK
                return (r.choice([0xCC, 0xCD]) << 8) | r.randrange(256)
            return 0x5500                               # NOP

    def two_word(self, ctx):
        r = self.r
        no_ar7 = ctx.get('no_ar7', False)
        kind = r.randrange(7)
        if kind == 0:
            a = r.randrange(7 if no_ar7 else 8)
            self.emit(0xD000 | (a << 8), self.pointer())             # LRLK
        else:
            shift = r.randrange(16)
            self.emit(0xD000 | (shift << 8) | kind, r.randrange(0x10000))

    def repeat_block(self, ctx):
        r = self.r
        if r.random() < 0.75:
            self.emit(0xCB00 | r.choice([0, 1, 2, 3, 5, 7, r.randrange(20)]))  # RPTK
        else:
            self.emit(0x4B00 | self.mem(not ctx.get('no_ar7', False)))       # RPT
        if r.random() < 0.2:
            self.blkd(ctx)
        else:
            self.emit(self.one_word(ctx))

    def blkd(self, ctx):
        self.emit(0xFD00 | self.mem(not ctx.get('no_ar7', False)), self.pointer())

    def ltd(self):
        # LTD's DMOV only moves within on-chip RAM; keep it off the 03FF edge
        dp = self.r.choice([0, 4, 5, 6, 7, 0x100])
        off = self.r.randrange(0x7F if dp == 7 else 0x80)
        self.emit(0xC800 | dp, 0x3F00 | off)

    def straight(self, n, ctx):
        for _ in range(n):
            k = self.r.random()
            if k < 0.80:
                self.emit(self.one_word(ctx))
            elif k < 0.88:
                self.two_word(ctx)
            elif k < 0.93:
                self.repeat_block(ctx)
            elif k < 0.97:
                self.blkd(ctx)
            else:
                self.ltd()

    def cond_branch(self, ctx, body):
        r = self.r
        op = r.choice(list(range(0xF0, 0xFB)) + [0xFB, 0xFF])
        low = r.choice([0x00, 0x80, self.indirect(not ctx.get('no_ar7', False))])
        target = self.new_label()
        self.emit((op << 8) | low)
        self.emit_ref(target)
        body()
        self.place(target)

    def banz_loop(self):
        r = self.r
        self.emit(0xC700 | r.randrange(1, 5))       # LARK AR7,n
        top = self.new_label()
        self.place(top)
        self.emit(0x5588 | r.randrange(7))          # LARP 0-6
        ctx = {'no_ar7': True}
        for _ in range(r.randrange(1, 10)):
            k = r.random()
            if k < 0.8:
                self.emit(self.one_word(ctx))
            elif k < 0.9:
                self.two_word(ctx)
            else:
                self.repeat_block(ctx)
        self.emit(0x558F)                           # LARP 7
        self.emit(0xFB90)                           # BANZ top,*-
        self.emit_ref(top)

    def build(self, nsubs=8, nblocks=900):
        r = self.r
        subs = ["S%d" % i for i in range(nsubs)]
        # initial state: pointers into every region
        for a in range(8):
            self.emit(0xD000 | (a << 8), self.pointer())
        self.emit(0xC800 | r.choice([4, 6, 0x100]))
        main_ctx = {'stack': True}
        for _ in range(nblocks):
            if len(self.code) > PROG_WORDS - 700:
                break
            k = r.random()
            if k < 0.55:
                self.straight(r.randrange(1, 8), main_ctx)
            elif k < 0.70:
                self.cond_branch(main_ctx, lambda: self.straight(r.randrange(1, 6), main_ctx))
            elif k < 0.78:
                self.emit(0xFE00 | r.choice([0x00, 0x80, self.indirect()]))   # CALL
                self.emit_ref(r.choice(subs))
            elif k < 0.83:
                self.emit(0xD001)                   # LALK sub ; CALA
                self.emit_ref(r.choice(subs))
                self.emit(0xCE24)
            elif k < 0.87:
                target = self.new_label()
                self.emit(0xD001)                   # LALK target ; BACC
                self.emit_ref(target)
                self.emit(0xCE25)
                self.straight(r.randrange(0, 4), main_ctx)
                self.place(target)
            elif k < 0.95:
                self.banz_loop()
            else:
                self.repeat_block(main_ctx)
        end = self.new_label()
        self.place(end)
        self.end_addr = len(self.code)
        self.emit(0xFF80)
        self.emit_ref(end)
        # leaf subroutines
        sub_ctx = {}
        for s in subs:
            self.place(s)
            for _ in range(r.randrange(1, 5)):
                if r.random() < 0.25:
                    self.cond_branch(sub_ctx, lambda: self.straight(r.randrange(1, 4), sub_ctx))
                else:
                    self.straight(r.randrange(1, 5), sub_ctx)
            self.emit(0xCE26)                       # RET
        for idx, label in self.fixups:
            self.code[idx] = self.labels[label]
        assert len(self.code) <= PROG_WORDS, len(self.code)
        return self.code

    def data(self):
        r = self.r
        out = []
        for _ in range(65536):
            x = r.random()
            if x < 0.15:
                out.append(r.randrange(8))
            elif x < 0.25:
                out.append(r.choice([0x0000, 0xFFFF, 0x8000, 0x7FFF, 0x0001]))
            else:
                out.append(r.randrange(0x10000))
        return out


def main():
    seed = int(sys.argv[1])
    g = Gen(seed)
    prog = g.build()
    data = g.data()
    with open(sys.argv[2], "w") as f:
        f.write("\n".join("%04x" % w for w in prog) + "\n")
    with open(sys.argv[3], "w") as f:
        f.write("\n".join("%04x" % w for w in data) + "\n")
    print("%04x" % g.end_addr)


if __name__ == "__main__":
    main()
