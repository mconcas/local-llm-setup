#!/usr/bin/env python3
"""Build a GGUF file with chosen metadata and an arbitrary apparent size.

Test fixtures only - nothing at runtime uses this. It exists because the models
the sizing checks have to reason about are the ones this board cannot hold: a
70B at CTX_SIZE=131072, a sliding-window model, a file whose KV head count
varies by layer. Written sparsely, so a "7 GiB model" costs a few KiB of disk,
which is the same constraint the objective puts on the real ones.

Only the metadata block is real; the tensor data is a hole. lib/gguf.py never
reads past the metadata, and neither does any check built on it.

Usage:
  mkgguf.py OUT.gguf [--arch qwen2] [--layers 36] [--embd 2048] [--heads 16]
            [--kv-heads 2] [--ctx-train 32768] [--vocab 151936]
            [--key-length N] [--value-length N] [--sliding-window N]
            [--kv-heads-per-layer 2,2,4,...] [--size-mib 512]
            [--omit KEY] [--version 3] [--truncate-metadata]
"""

import argparse
import os
import struct
import sys

_T_UINT32, _T_UINT64, _T_STRING, _T_ARRAY = 4, 10, 8, 9


def _str(s):
    b = s.encode("utf-8")
    return struct.pack("<Q", len(b)) + b


def _kv_u32(key, val):
    return _str(key) + struct.pack("<I", _T_UINT32) + struct.pack("<I", val)


def _kv_str(key, val):
    return _str(key) + struct.pack("<I", _T_STRING) + _str(val)


def _kv_u32_array(key, vals):
    return (_str(key) + struct.pack("<I", _T_ARRAY)
            + struct.pack("<I", _T_UINT32) + struct.pack("<Q", len(vals))
            + b"".join(struct.pack("<I", v) for v in vals))


def _kv_str_array(key, vals):
    return (_str(key) + struct.pack("<I", _T_ARRAY)
            + struct.pack("<I", _T_STRING) + struct.pack("<Q", len(vals))
            + b"".join(_str(v) for v in vals))


def build(a):
    arch = a.arch
    kv = []

    def add(key, val, kind=_kv_u32):
        if key in a.omit:
            return
        kv.append(kind(key, val))

    add("general.architecture", arch, _kv_str)
    add("%s.block_count" % arch, a.layers)
    add("%s.embedding_length" % arch, a.embd)
    if a.kv_heads_per_layer:
        add("%s.attention.head_count" % arch, a.heads)
        add("%s.attention.head_count_kv" % arch,
            [int(x) for x in a.kv_heads_per_layer.split(",")], _kv_u32_array)
    else:
        add("%s.attention.head_count" % arch, a.heads)
        add("%s.attention.head_count_kv" % arch, a.kv_heads)
    if a.key_length is not None:
        add("%s.attention.key_length" % arch, a.key_length)
    if a.value_length is not None:
        add("%s.attention.value_length" % arch, a.value_length)
    if a.sliding_window is not None:
        add("%s.attention.sliding_window" % arch, a.sliding_window)
    add("%s.context_length" % arch, a.ctx_train)
    # A realistic vocabulary array: this is the one field the reader is expected
    # to take the *length* of without materialising, so make it big enough that
    # doing it the other way would be visible.
    if "tokenizer.ggml.tokens" not in a.omit:
        kv.append(_kv_str_array("tokenizer.ggml.tokens",
                                ["t%d" % i for i in range(a.vocab)]))

    body = b"".join(kv)
    head = (b"GGUF" + struct.pack("<I", a.version)
            + struct.pack("<Q", a.tensors) + struct.pack("<Q", len(kv)))
    return head + body


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--arch", default="qwen2")
    p.add_argument("--layers", type=int, default=36)
    p.add_argument("--embd", type=int, default=2048)
    p.add_argument("--heads", type=int, default=16)
    p.add_argument("--kv-heads", type=int, default=2)
    p.add_argument("--kv-heads-per-layer", default="")
    p.add_argument("--key-length", type=int)
    p.add_argument("--value-length", type=int)
    p.add_argument("--sliding-window", type=int)
    p.add_argument("--ctx-train", type=int, default=32768)
    p.add_argument("--vocab", type=int, default=1024)
    p.add_argument("--tensors", type=int, default=434)
    p.add_argument("--version", type=int, default=3)
    p.add_argument("--size-mib", type=int, default=0)
    p.add_argument("--omit", action="append", default=[])
    p.add_argument("--truncate-metadata", action="store_true",
                   help="cut the file off inside the metadata block")
    a = p.parse_args(argv[1:])

    data = build(a)
    if a.truncate_metadata:
        data = data[:len(data) // 2]
    with open(a.out, "wb") as fh:
        fh.write(data)
        if a.size_mib and not a.truncate_metadata:
            want = a.size_mib * 1048576
            if want > len(data):
                fh.truncate(want)          # sparse: costs no disk
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
