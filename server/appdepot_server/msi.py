"""Read the Property table of an MSI file without Windows APIs.

An MSI is an OLE compound document. Table streams have mangled names and
string columns are indexes into a shared string pool. Only what AppDepot
needs is implemented: ``ProductCode``, ``ProductVersion``, ``UpgradeCode``,
``ProductName``, ``Manufacturer`` and ``ALLUSERS``.
"""

from __future__ import annotations

import struct
from pathlib import Path

import olefile

_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._"


def decode_stream_name(name: str) -> str:
    out = []
    for ch in name:
        c = ord(ch)
        if 0x3800 <= c < 0x4800:
            c -= 0x3800
            out.append(_CHARSET[c & 0x3F])
            out.append(_CHARSET[(c >> 6) & 0x3F])
        elif 0x4800 <= c < 0x4840:
            out.append(_CHARSET[c - 0x4800])
        elif c == 0x4840:
            out.append("!")
        else:
            out.append(ch)
    return "".join(out)


def _codec(codepage: int) -> str:
    if codepage in (0, 65001):
        return "utf-8"
    return f"cp{codepage}"


def _read_strings(pool: bytes, data: bytes) -> tuple[list[str], int]:
    words = struct.unpack(f"<{len(pool) // 2}H", pool[: len(pool) // 2 * 2])
    codepage = words[0] | ((words[1] & ~0x8000) << 16)
    ref_size = 3 if words[1] & 0x8000 else 2
    codec = _codec(codepage)
    strings = [""]  # string id 0 = null
    offset = 0
    i = 1
    count = len(words) // 2
    while i < count:
        length, refs = words[i * 2], words[i * 2 + 1]
        if length == 0 and refs == 0:
            strings.append("")
            i += 1
            continue
        if length == 0:  # string longer than 64k: real length is the next 32-bit value
            length = words[i * 2 + 2] | (words[i * 2 + 3] << 16)
            i += 2
        else:
            i += 1
        raw = data[offset: offset + length]
        offset += length
        try:
            strings.append(raw.decode(codec))
        except (UnicodeDecodeError, LookupError):
            strings.append(raw.decode("latin-1"))
    return strings, ref_size


def read_msi_properties(path: str | Path) -> dict[str, str]:
    with olefile.OleFileIO(str(path)) as ole:
        streams = {decode_stream_name(entry[-1]): entry for entry in ole.listdir()}
        try:
            pool = ole.openstream(streams["!_StringPool"]).read()
            data = ole.openstream(streams["!_StringData"]).read()
            table = ole.openstream(streams["!Property"]).read()
        except KeyError as exc:
            raise ValueError(f"{path} does not look like an MSI database") from exc

    strings, ref_size = _read_strings(pool, data)
    rows = len(table) // (2 * ref_size)

    def ref(col: int, row: int) -> str:
        start = (col * rows + row) * ref_size
        raw = table[start: start + ref_size]
        idx = int.from_bytes(raw, "little")
        return strings[idx] if idx < len(strings) else ""

    return {ref(0, r): ref(1, r) for r in range(rows)}


def msi_summary(path: str | Path) -> dict[str, str | None]:
    props = read_msi_properties(path)
    keys = ("ProductCode", "ProductVersion", "ProductName", "Manufacturer", "UpgradeCode", "ALLUSERS")
    return {k: props.get(k) for k in keys}
