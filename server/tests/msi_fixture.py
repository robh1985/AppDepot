"""Build a minimal but genuine MSI (OLE compound file) for tests.

Contains the string pool and a Property table, which is all AppDepot reads.
All streams are smaller than 4096 bytes so they live in the mini stream.
"""

from __future__ import annotations

import struct

CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._"
SECTOR, MINI = 512, 64
FREESECT, ENDOFCHAIN, FATSECT, NOSTREAM = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFF


def encode_table_name(name: str) -> str:
    out = [chr(0x4840)]
    for i in range(0, len(name) - 1, 2):
        out.append(chr(0x3800 + CHARSET.index(name[i]) + (CHARSET.index(name[i + 1]) << 6)))
    if len(name) % 2:
        out.append(chr(0x4800 + CHARSET.index(name[-1])))
    return "".join(out)


def _string_tables(props: dict[str, str], codepage: int = 1252):
    strings: list[str] = []
    for k, v in props.items():
        for s in (k, v):
            if s not in strings:
                strings.append(s)
    pool = struct.pack("<HH", codepage & 0xFFFF, codepage >> 16)
    data = b""
    for s in strings:
        raw = s.encode(f"cp{codepage}")
        pool += struct.pack("<HH", len(raw), 1)
        data += raw
    ids = {s: i + 1 for i, s in enumerate(strings)}
    table = b"".join(struct.pack("<H", ids[k]) for k in props) + \
        b"".join(struct.pack("<H", ids[v]) for v in props.values())
    return pool, data, table


def _dir_entry(name: str, etype: int, child=NOSTREAM, right=NOSTREAM, start=0, size=0) -> bytes:
    encoded = name.encode("utf-16-le") + b"\0\0"
    return (encoded.ljust(64, b"\0") + struct.pack("<HBB", len(encoded), etype, 1)
            + struct.pack("<III", NOSTREAM, right, child) + b"\0" * 16 + b"\0" * 4
            + b"\0" * 16 + struct.pack("<IQ", start, size))


def build_msi(props: dict[str, str]) -> bytes:
    pool, data, table = _string_tables(props)
    return build_ole([(encode_table_name("_StringPool"), pool), (encode_table_name("_StringData"), data),
                      (encode_table_name("Property"), table)])


def summary_information(template: str, codepage: int = 1252) -> bytes:
    """A SummaryInformation property set holding PID_CODEPAGE (1) and PID_TEMPLATE (7)."""
    fmtid = bytes.fromhex("E0859FF2F94F6810AB9108002B27B3D9")
    text = template.encode("latin-1") + b"\0"
    text += b"\0" * (-len(text) % 4)
    props = [(1, struct.pack("<IhH", 0x02, codepage, 0)),                       # VT_I2
             (7, struct.pack("<II", 0x1E, len(template) + 1) + text)]           # VT_LPSTR
    header_len = 8 + 8 * len(props)
    offsets, body = [], b""
    for pid, value in props:
        offsets.append((pid, header_len + len(body)))
        body += value
    section = struct.pack("<II", header_len + len(body), len(props)) + \
        b"".join(struct.pack("<II", pid, off) for pid, off in offsets) + body
    return struct.pack("<HHI", 0xFFFE, 0, 0x00020006) + b"\0" * 16 + struct.pack("<I", 1) + \
        fmtid + struct.pack("<I", 48) + section


def build_msp(target_product_codes: list[str]) -> bytes:
    """A minimal .msp: summary information whose Template lists the target ProductCodes."""
    return build_ole([("\x05SummaryInformation", summary_information(";".join(target_product_codes))),
                      (encode_table_name("_StringPool"), struct.pack("<HH", 1252, 0)),
                      (encode_table_name("_StringData"), b"")])


def build_ole(streams: list[tuple[str, bytes]]) -> bytes:

    # mini stream + mini FAT
    mini = b""
    minifat: list[int] = []
    starts = []
    for _, content in streams:
        n = max(1, -(-len(content) // MINI))
        first = len(minifat)
        starts.append(first)
        minifat += [first + i + 1 for i in range(n - 1)] + [ENDOFCHAIN]
        mini += content.ljust(n * MINI, b"\0")

    n_dir = -(-(1 + len(streams)) // 4)
    n_minifat = -(-len(minifat) * 4 // SECTOR)
    n_mini = -(-len(mini) // SECTOR)
    # sector layout: [FAT][dir...][minifat...][ministream...]
    dir_start, minifat_start = 1, 1 + n_dir
    mini_start = minifat_start + n_minifat
    total = mini_start + n_mini

    fat = [FATSECT]
    for start, count in ((dir_start, n_dir), (minifat_start, n_minifat), (mini_start, n_mini)):
        fat += [start + i + 1 for i in range(count - 1)] + [ENDOFCHAIN]
    assert len(fat) == total <= SECTOR // 4
    fat_sector = b"".join(struct.pack("<I", x) for x in fat).ljust(SECTOR, b"\xff")

    entries = [_dir_entry("Root Entry", 5, child=1, start=mini_start, size=len(mini))]
    for i, ((name, content), start) in enumerate(zip(streams, starts)):
        right = i + 2 if i + 1 < len(streams) else NOSTREAM
        entries.append(_dir_entry(name, 2, right=right, start=start, size=len(content)))
    # unused directory slots must be empty entries with NOSTREAM links
    empty = b"\0" * 64 + struct.pack("<HBB", 0, 0, 0) + struct.pack("<III", NOSTREAM, NOSTREAM, NOSTREAM) + b"\0" * 52
    dir_bytes = b"".join(entries) + empty * (n_dir * 4 - len(entries))

    minifat_bytes = b"".join(struct.pack("<I", x) for x in minifat).ljust(n_minifat * SECTOR, b"\xff")

    header = (bytes.fromhex("D0CF11E0A1B11AE1") + b"\0" * 16
              + struct.pack("<HHHHH", 0x3E, 3, 0xFFFE, 9, 6) + b"\0" * 6
              + struct.pack("<IIIIIIIII", 0, 1, dir_start, 0, 4096, minifat_start, n_minifat,
                            ENDOFCHAIN, 0)
              + struct.pack("<I", 0) + b"\xff" * (109 * 4 - 4))
    assert len(header) == SECTOR
    return header + fat_sector + dir_bytes + minifat_bytes + mini.ljust(n_mini * SECTOR, b"\0")
