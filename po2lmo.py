#!/usr/bin/env python3
"""Faithful port of OpenWrt LuCI's po2lmo (modules/luci-base/src/po2lmo.c +
lib/lmo.c's sfh_hash), producing real LMO catalogs that LuCI's runtime i18n
loader (lib/lmo.c: lmo_open/lmo_translate) can actually read.

The previous version of this file invented its own format (a 16-byte magic
header + a "jenkins" hash that doesn't exist anywhere in LuCI) and was never
a valid LMO file. LuCI's loader locates the index purely from the LAST 4
bytes of the file (the string-data length) — the extra header shifted every
offset, and lmo_load_catalog() aggregates every "*.<lang>.lmo" file it finds
into ONE shared per-language search list, so the malformed file corrupted
lookups for the WHOLE language, not just this package's own strings.

File layout (matches upstream exactly):
    [value bytes for every entry, each padded to a 4-byte boundary, in the
     order they were emitted] [index: one (key_id, val_id, offset, length)
     big-endian uint32 quartet per entry, SORTED by key_id ascending]
    [one trailing big-endian uint32: the total (padded) length of the value
     section above — this is what the loader reads first, from EOF-4]
"""
import struct
import sys


def _get16(data, i):
    """Little-endian 16-bit read — matches lib/lmo.h's sfh_get16 macro,
    which is little-endian on every arch (not just __i386__)."""
    return data[i] | (data[i + 1] << 8)


def sfh_hash(data: bytes, init: int) -> int:
    """Paul Hsieh's SuperFastHash, ported bit-for-bit from lib/lmo.c. This is
    the ONLY hash LMO files use — not a Jenkins/one-at-a-time hash."""
    length = len(data)
    if length <= 0:
        return 0
    h = init & 0xFFFFFFFF
    rem = length & 3
    i = 0
    for _ in range(length >> 2):
        h = (h + _get16(data, i)) & 0xFFFFFFFF
        tmp = ((_get16(data, i + 2) << 11) ^ h) & 0xFFFFFFFF
        h = ((h << 16) & 0xFFFFFFFF) ^ tmp
        i += 4
        h = (h + (h >> 11)) & 0xFFFFFFFF

    def _schar(b):
        return b - 256 if b >= 128 else b

    if rem == 3:
        h = (h + _get16(data, i)) & 0xFFFFFFFF
        h ^= (h << 16) & 0xFFFFFFFF
        h = (h ^ ((_schar(data[i + 2]) << 18) & 0xFFFFFFFF)) & 0xFFFFFFFF
        h = (h + (h >> 11)) & 0xFFFFFFFF
    elif rem == 2:
        h = (h + _get16(data, i)) & 0xFFFFFFFF
        h ^= (h << 11) & 0xFFFFFFFF
        h = (h + (h >> 17)) & 0xFFFFFFFF
    elif rem == 1:
        h = (h + _schar(data[i])) & 0xFFFFFFFF
        h ^= (h << 10) & 0xFFFFFFFF
        h = (h + (h >> 1)) & 0xFFFFFFFF

    h ^= (h << 3) & 0xFFFFFFFF
    h = (h + (h >> 5)) & 0xFFFFFFFF
    h ^= (h << 4) & 0xFFFFFFFF
    h = (h + (h >> 17)) & 0xFFFFFFFF
    h ^= (h << 25) & 0xFFFFFFFF
    h = (h + (h >> 6)) & 0xFFFFFFFF
    return h


def _extract_string(line: str):
    """Port of po2lmo.c's extract_string(): pulls the quoted payload out of
    a `msgid "..."` / bare `"..."` continuation line. Unescapes ONLY \\" and
    \\\\, matching the real tool byte-for-byte — any other backslash
    sequence (e.g. \\n) is kept as the literal two characters, exactly as
    upstream does (the header-field scan below relies on that)."""
    if line.startswith('#'):
        return None
    dest = []
    started = False
    esc = False
    for ch in line:
        if not started:
            if ch == '"':
                started = True
            continue
        if esc:
            if ch == '"' or ch == '\\':
                dest[-1] = ch  # overwrite the backslash tentatively appended below
            else:
                dest.append(ch)  # not a recognized escape: keep backslash AND ch
            esc = False
        elif ch == '\\':
            dest.append(ch)
            esc = True
        elif ch == '"':
            return ''.join(dest)
        else:
            dest.append(ch)
    return ''.join(dest) if started else None


class _Msg:
    __slots__ = ("ctxt", "id", "id_plural", "val", "plural_num", "cur")

    def __init__(self):
        self.ctxt = None
        self.id = None
        self.id_plural = None
        self.val = [None] * 10
        self.plural_num = 0
        self.cur = None  # (field, index) — field in {ctxt, id, id_plural, val}

    def append(self, text):
        field, idx = self.cur
        if field == 'val':
            self.val[idx] = (self.val[idx] or '') + text
        else:
            setattr(self, field, (getattr(self, field) or '') + text)


def _emit(msg: _Msg, string_data: bytearray, entries: list, offset: int) -> int:
    """Port of po2lmo.c's print_msg(). Appends value bytes to string_data
    (each padded to a 4-byte boundary) and (key_id, val_id, offset, length)
    tuples to entries; returns the advanced offset."""
    if msg.id and msg.val[0] is not None:
        for i in range(msg.plural_num + 1):
            v = msg.val[i]
            if v is None:
                continue
            if msg.ctxt and msg.id_plural:
                key = "%s\1%s\2%d" % (msg.ctxt, msg.id, i)
            elif msg.ctxt:
                key = "%s\1%s" % (msg.ctxt, msg.id)
            elif msg.id_plural:
                key = "%s\2%d" % (msg.id, i)
            else:
                key = msg.id

            key_bytes = key.encode('utf-8')
            val_bytes = v.encode('utf-8')
            key_id = sfh_hash(key_bytes, len(key_bytes))
            val_id = sfh_hash(val_bytes, len(val_bytes))

            if key_id != val_id:  # upstream's "don't store a no-op translation" heuristic
                length = len(val_bytes)
                entries.append((key_id, msg.plural_num + 1, offset, length))
                pad = (4 - (length % 4)) % 4
                string_data += val_bytes + b'\0' * pad
                offset += length + pad
    elif msg.val[0] is not None:
        # header block (empty msgid): extract_string never turns the .po
        # file's literal "\n" into a real newline (see its docstring), so
        # the header text is one string with literal backslash-n joins —
        # split on that to find the Plural-Forms line, same as upstream.
        for part in msg.val[0].split('\\n'):
            if part.lower().startswith("plural-forms: "):
                text_bytes = part[len("plural-forms: "):].encode('utf-8')
                length = len(text_bytes)
                entries.append((0, 0, offset, length))
                pad = (4 - (length % 4)) % 4
                string_data += text_bytes + b'\0' * pad
                offset += length + pad
                break

    return offset


def compile_po(filename):
    entries = []
    string_data = bytearray()
    offset = 0
    msg = _Msg()

    with open(filename, 'r', encoding='utf-8') as f:
        raw_lines = f.read().split('\n')

    for i in range(len(raw_lines) + 1):
        eof = i == len(raw_lines)
        line = '' if eof else raw_lines[i].rstrip('\r')

        if not eof and line.startswith('msgctxt "'):
            offset = _emit(msg, string_data, entries, offset)
            msg = _Msg()
            msg.cur = ('ctxt', 0)
        elif eof or line.startswith('msgid "'):
            offset = _emit(msg, string_data, entries, offset)
            msg = _Msg()
            msg.cur = ('id', 0)
        elif line.startswith('msgid_plural "'):
            msg.id_plural = None
            msg.cur = ('id_plural', 0)
        elif line.startswith('msgstr "') or line.startswith('msgstr['):
            n = int(line[7:line.index(']')]) if line[6] == '[' else 0
            if n >= 10:
                raise ValueError("too many plural forms")
            msg.plural_num = n
            msg.val[n] = None
            msg.cur = ('val', n)

        if eof:
            break

        if msg.cur is not None:
            text = _extract_string(line)
            if text:
                msg.append(text)

    return entries, string_data, offset


def write_lmo(filename, out_filename):
    entries, string_data, offset = compile_po(filename)

    if offset <= 0:
        # upstream unlinks the output rather than emitting an empty catalog
        import os
        if os.path.exists(out_filename):
            os.remove(out_filename)
        return

    entries.sort(key=lambda e: e[0])  # index must be sorted by key_id: lmo_find_entry binary-searches it

    with open(out_filename, 'wb') as f:
        f.write(bytes(string_data))
        for key_id, val_id, val_offset, length in entries:
            f.write(struct.pack(">IIII", key_id, val_id, val_offset, length))
        f.write(struct.pack(">I", offset))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.stderr.write("usage: %s input.po output.lmo\n" % sys.argv[0])
        sys.exit(1)
    write_lmo(sys.argv[1], sys.argv[2])
