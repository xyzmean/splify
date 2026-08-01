#!/usr/bin/env python3
"""Minimal DNS upstream for the splify-dnsd lab.

Answers every A query with whatever address is in --ip-file, so a CDN moving a
domain to a new backend is one `echo` away — that is the case that matters
(two domains on one Cloudflare address, and the address rotating under us).
Deterministic, offline, and nothing here touches a real router.
"""
import argparse
import socket
import struct
import sys
from pathlib import Path


def parse_qname(buf, off):
    labels = []
    while True:
        n = buf[off]
        off += 1
        if n == 0:
            break
        if n & 0xC0:                      # compression pointer: not used in queries
            raise ValueError("compressed qname in a query")
        labels.append(buf[off:off + n].decode("ascii", "replace"))
        off += n
    return ".".join(labels), off


def build_answer(query, ip, ttl):
    txid = query[:2]
    qname, qend = parse_qname(query, 12)
    qtype, qclass = struct.unpack("!HH", query[qend:qend + 4])
    qend += 4
    header = txid + struct.pack("!HHHHH", 0x8180, 1, 1 if qtype == 1 else 0, 0, 0)
    body = query[12:qend]
    if qtype != 1:                        # only A records get an answer section
        return header + body, qname, qtype
    rr = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, ttl, 4) + socket.inet_aton(ip)
    return header + body + rr, qname, qtype


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5353)
    ap.add_argument("--ip-file", required=True, help="file holding the A answer")
    ap.add_argument("--ttl", type=int, default=69)
    a = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", a.port))
    print(f"fake upstream on 127.0.0.1:{a.port}, answer from {a.ip_file}", flush=True)
    while True:
        try:
            q, peer = s.recvfrom(4096)
            ip = Path(a.ip_file).read_text().strip() or "203.0.113.1"
            resp, qname, qtype = build_answer(q, ip, a.ttl)
            s.sendto(resp, peer)
            print(f"  {qname} type={qtype} -> {ip}", flush=True)
        except KeyboardInterrupt:
            return 0
        except Exception as e:                     # keep the lab alive on bad input
            print(f"  error: {e}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
