#!/usr/bin/env python3
"""Shared helpers: Oric HIRES encoding, decoding to RGB, LZ compression.

Oric HIRES bytes: bit6 set = 6 pixels (bit5 leftmost) in the current ink /
paper; bit6 and bit5 clear = serial attribute (0-7 ink, 16-23 paper), shown
as 6 pixels of (new) paper colour.  Attributes reset at the start of each
scanline to ink white, paper black.
"""
import struct
import zlib

PAL = [(0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0),
       (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]


def decode_rows(rows):
    """rows: list of 40-byte lists -> list of 240-pixel colour-index rows."""
    out = []
    for r in rows:
        ink, paper = 7, 0
        line = []
        for b in r:
            inv = 7 if b & 0x80 else 0
            if (b & 0x60) == 0:
                v = b & 0x1F
                if v < 8:
                    ink = v
                elif 16 <= v < 24:
                    paper = v - 16
                line += [paper ^ inv] * 6
            else:
                for p in range(6):
                    line.append((ink if b & (0x20 >> p) else paper) ^ inv)
        out.append(line)
    return out


def encode_line(target, start_ink=7, start_paper=0, fixed=None, inks=range(8)):
    """Best Oric encoding of one 240-pixel scanline of colour indices.

    Dynamic programming over (ink, paper) state; each 6-pixel group is either
    a pixel byte in the current colours or an attribute changing ink or paper.
    fixed: optional {col: byte} forcing particular bytes.  Returns 40 bytes.
    """
    INF = 1 << 30
    groups = [target[c * 6:c * 6 + 6] for c in range(40)]
    cost = {(start_ink, start_paper): 0}
    back = []
    for c in range(40):
        g = groups[c]
        ncost = {}
        nback = {}
        f = fixed.get(c) if fixed else None
        for (ink, paper), base in cost.items():
            cands = []
            if f is not None:
                if (f & 0x60) == 0:
                    v = f & 0x1F
                    ni, np_ = ink, paper
                    if v < 8:
                        ni = v
                    elif 16 <= v < 24:
                        np_ = v - 16
                    err = sum(1 for p in g if p != np_)
                    cands.append((ni, np_, f, err))
                else:
                    inv = 7 if f & 0x80 else 0
                    err = sum(1 for k, p in enumerate(g)
                              if p != ((ink if f & (0x20 >> k) else paper) ^ inv))
                    cands.append((ink, paper, f, err))
            else:
                # pixel byte: each pixel picks ink or paper, whichever matches
                bits = 0
                err = 0
                for k, p in enumerate(g):
                    if p == ink and p != paper:
                        bits |= 0x20 >> k
                    elif p != paper:
                        err += 1
                cands.append((ink, paper, 0x40 | bits, err))
                # inverse video: the byte shows 7-ink / 7-paper
                ii, ip = ink ^ 7, paper ^ 7
                bits = 0
                err = 0
                for k, p in enumerate(g):
                    if p == ii and p != ip:
                        bits |= 0x20 >> k
                    elif p != ip:
                        err += 1
                cands.append((ink, paper, 0xC0 | bits, err))
                for v in range(8):
                    if v != ink and v in inks:
                        cands.append((v, paper, v, sum(1 for p in g if p != paper) + 0))
                    if v != paper:
                        cands.append((ink, v, 16 + v, sum(1 for p in g if p != v)))
            for ni, np_, byte, err in cands:
                # tiny bias against attributes so pixel bytes win ties
                tot = base + err * 16 + ((byte & 0x60) == 0)
                key = (ni, np_)
                if tot < ncost.get(key, INF):
                    ncost[key] = tot
                    nback[key] = ((ink, paper), byte)
        back.append(nback)
        cost = ncost
    state = min(cost, key=cost.get)
    out = []
    for c in range(39, -1, -1):
        prev, byte = back[c][state]
        out.append(byte)
        state = prev
    return out[::-1]


def encode_image(img, fixed_cols=None):
    """img: list of 240-wide colour-index rows -> list of 40-byte rows."""
    return [encode_line(r, fixed=fixed_cols) for r in img]


def lz_compress(data):
    """Simple LZ: token t: 1..127 literal run of t bytes; 128..255 match of
    (t & 127) + 3 bytes at distance d (2 bytes LE, 1..65535); 0 = end."""
    data = bytes(data)
    n = len(data)
    out = bytearray()
    lit = bytearray()
    i = 0
    # index of 3-byte prefixes
    table = {}

    def flush():
        nonlocal lit
        while lit:
            chunk = lit[:127]
            out.append(len(chunk))
            out.extend(chunk)
            lit = lit[127:]

    while i < n:
        best_len, best_d = 0, 0
        if i + 3 <= n:
            key = data[i:i + 3]
            for j in reversed(table.get(key, [])[-64:]):
                l = 0
                while i + l < n and l < 130 and data[j + l] == data[i + l]:
                    l += 1
                if l > best_len:
                    best_len, best_d = l, i - j
                    if l == 130:
                        break
        if best_len >= 4 or (best_len == 3 and not lit):
            flush()
            out.append(0x80 | (best_len - 3))
            out += struct.pack('<H', best_d)
            for k in range(best_len):
                if i + k + 3 <= n:
                    table.setdefault(data[i + k:i + k + 3], []).append(i + k)
            i += best_len
        else:
            if i + 3 <= n:
                table.setdefault(data[i:i + 3], []).append(i)
            lit.append(data[i])
            i += 1
    flush()
    out.append(0)
    return bytes(out)


def lz_decompress(comp):
    out = bytearray()
    i = 0
    while True:
        t = comp[i]
        i += 1
        if t == 0:
            return bytes(out)
        if t < 128:
            out += comp[i:i + t]
            i += t
        else:
            l = (t & 127) + 3
            d = comp[i] | (comp[i + 1] << 8)
            i += 2
            for _ in range(l):
                out.append(out[-d])


def write_png(path, idx_rows, scale=2):
    h = len(idx_rows)
    w = len(idx_rows[0])
    raw = bytearray()
    for r in idx_rows:
        row = bytearray()
        for p in r:
            row += bytes(PAL[p]) * scale
        for _ in range(scale):
            raw.append(0)
            raw += row

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def emit_bytes(out, vals, per=32):
    for i in range(0, len(vals), per):
        out.append("        .byte " + ",".join("$%02X" % v for v in vals[i:i + per]))
