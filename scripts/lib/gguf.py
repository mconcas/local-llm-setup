#!/usr/bin/env python3
"""Read the metadata a GGUF file needs to size its KV cache, and print it as
shell-assignable GGUF_* lines.

Why this exists: on a Jetson the weights are the *small* part of the decision.
An 8 GB board shares one pool between the CPU and the GPU, and a 1.8 GiB model
at CTX_SIZE=16384 asks for another 306 MiB of KV cache and ~305 MiB of compute
buffers. Sizing on the file size alone - which is what this repo did until now -
answers a question nobody asked: the container loads, reports healthy, and then
dies once the cache fills. The numbers that decide it are in the file's own
metadata, so read them rather than guess.

Only the metadata block is read; the tensor data is never touched, so this costs
a few hundred KiB of I/O on a multi-gigabyte file.

Usage:   gguf.py <file.gguf>
Output:  GGUF_ARCH=qwen2
         GGUF_N_LAYER=36
         ...
         GGUF_K_ELEMS_PER_TOKEN=9216     # summed over layers, ready to multiply
         GGUF_V_ELEMS_PER_TOKEN=9216
         GGUF_ESTIMATE_CAVEAT=            # non-empty when the sum is an upper bound

Every value is a decimal integer or a [A-Za-z0-9_.-] token, so the output is
safe to `eval` - the same contract detect-platform.sh --env has. Exits 2 with a
reason on stderr when the file is not a GGUF or is missing a field the estimate
needs; a caller must treat that as "cannot estimate", never as zero.
"""

import struct
import sys

# GGUF metadata value types.
_T_UINT8, _T_INT8, _T_UINT16, _T_INT16 = 0, 1, 2, 3
_T_UINT32, _T_INT32, _T_FLOAT32, _T_BOOL = 4, 5, 6, 7
_T_STRING, _T_ARRAY, _T_UINT64, _T_INT64, _T_FLOAT64 = 8, 9, 10, 11, 12

_SCALAR = {
    _T_UINT8: ("<B", 1), _T_INT8: ("<b", 1),
    _T_UINT16: ("<H", 2), _T_INT16: ("<h", 2),
    _T_UINT32: ("<I", 4), _T_INT32: ("<i", 4),
    _T_FLOAT32: ("<f", 4), _T_BOOL: ("<?", 1),
    _T_UINT64: ("<Q", 8), _T_INT64: ("<q", 8),
    _T_FLOAT64: ("<d", 8),
}

# Architectures whose KV cache is not n_ctx * layers * n_embd_gqa. Each is named
# rather than lumped into a single "unsupported" branch, because the caller
# prints the reason and "we do not model this" is a more useful answer than a
# number that is quietly too large.
_CAVEATS = {
    "deepseek2": "this architecture uses MLA, whose cache is a latent vector "
                 "rather than per-head K/V - the real cache is smaller",
    "kimi_k2": "this architecture uses MLA, whose cache is a latent vector "
               "rather than per-head K/V - the real cache is smaller",
}


class GgufError(Exception):
    pass


class _Reader:
    """A forward-only reader over the metadata block.

    Arrays are skipped without materialising them: a tokenizer vocabulary is
    150k strings, and the only thing this program wants from it is its length.
    """

    def __init__(self, fh):
        self.fh = fh

    def raw(self, n):
        b = self.fh.read(n)
        if len(b) != n:
            raise GgufError("file ends inside its metadata block")
        return b

    def scalar(self, t):
        fmt, size = _SCALAR[t]
        return struct.unpack(fmt, self.raw(size))[0]

    def string(self):
        n = self.scalar(_T_UINT64)
        if n > (1 << 24):
            raise GgufError("implausible string length in metadata (%d bytes)" % n)
        return self.raw(n).decode("utf-8", "replace")

    def value(self, t, keep):
        """Read one value. `keep` false means skip it as cheaply as possible."""
        if t == _T_STRING:
            s = self.string()
            return s if keep else None
        if t == _T_ARRAY:
            et = self.scalar(_T_UINT32)
            n = self.scalar(_T_UINT64)
            if et == _T_ARRAY:
                raise GgufError("nested arrays in metadata are not supported")
            if et == _T_STRING:
                # Variable width: every element has to be walked even to skip it.
                out = []
                for _ in range(n):
                    s = self.string()
                    if keep:
                        out.append(s)
                return _Array(n, out if keep else None)
            if et not in _SCALAR:
                raise GgufError("unknown array element type %d" % et)
            width = _SCALAR[et][1]
            if keep:
                fmt, _ = _SCALAR[et]
                return _Array(n, [struct.unpack(fmt, self.raw(width))[0]
                                  for _ in range(n)])
            self.fh.seek(n * width, 1)
            return _Array(n, None)
        if t not in _SCALAR:
            raise GgufError("unknown metadata value type %d" % t)
        v = self.scalar(t)
        return v if keep else None


class _Array:
    def __init__(self, length, items):
        self.length = length
        self.items = items


# Which keys are worth recording, and - separately - which are worth reading the
# *contents* of. A tokenizer vocabulary is a 150k-entry array whose only useful
# property here is its length, and an array's length is known before any of its
# elements are, so it is recorded without ever being materialised.
def _wanted(key, arch):
    if key in ("general.architecture", "general.file_type",
               "tokenizer.ggml.tokens"):
        return True
    if arch is None:
        # general.architecture leads every file this has seen, but do not depend
        # on it: an arch-prefixed key read before it would otherwise be skipped.
        return "." in key
    return key.startswith(arch + ".")


def _wanted_items(key, arch):
    return key != "tokenizer.ggml.tokens" and _wanted(key, arch)


def read_metadata(path):
    with open(path, "rb") as fh:
        r = _Reader(fh)
        if r.raw(4) != b"GGUF":
            raise GgufError("not a GGUF file (bad magic bytes)")
        version = r.scalar(_T_UINT32)
        if version not in (2, 3):
            raise GgufError("unsupported GGUF version %d (this reads v2 and v3)"
                            % version)
        r.scalar(_T_UINT64)                       # tensor count
        n_kv = r.scalar(_T_UINT64)
        if n_kv > 1 << 20:
            raise GgufError("implausible metadata key count (%d)" % n_kv)

        md, arch = {}, None
        for _ in range(n_kv):
            key = r.string()
            t = r.scalar(_T_UINT32)
            val = r.value(t, _wanted_items(key, arch))
            if _wanted(key, arch):
                md[key] = val
            if key == "general.architecture":
                arch = val
        if arch is None:
            raise GgufError("no general.architecture in the metadata")
        return arch, md


def _int(md, key, default=None):
    v = md.get(key, default)
    if isinstance(v, _Array):
        raise GgufError("%s is an array; expected a single value" % key)
    if v is None:
        raise GgufError("no %s in the metadata" % key)
    return int(v)


def _per_layer(md, key, n_layer):
    """Return a per-layer list for a key that may be a scalar or an array.

    Several architectures (Llama 4, Gemma 3n, Jamba) vary the KV head count by
    layer, and a file that does is exactly the file whose cache a scalar
    estimate gets wrong. Missing entirely is a different answer from present:
    the caller supplies the fallback.
    """
    v = md.get(key)
    if v is None:
        return None
    if isinstance(v, _Array):
        if v.items is None or len(v.items) == 0:
            raise GgufError("%s is an empty array" % key)
        items = [int(x) for x in v.items]
        if len(items) < n_layer:
            items = items + [items[-1]] * (n_layer - len(items))
        return items[:n_layer]
    return [int(v)] * n_layer


def describe(path):
    arch, md = read_metadata(path)

    n_layer = _int(md, "%s.block_count" % arch)
    n_embd = _int(md, "%s.embedding_length" % arch)
    n_head = _per_layer(md, "%s.attention.head_count" % arch, n_layer)
    if n_head is None:
        raise GgufError("no %s.attention.head_count in the metadata" % arch)
    n_head_kv = _per_layer(md, "%s.attention.head_count_kv" % arch, n_layer)
    if n_head_kv is None:
        n_head_kv = list(n_head)              # no GQA: one KV head per Q head

    # key_length / value_length are optional and default to n_embd / n_head.
    # They are not always equal (DeepSeek, some MoE models), so keep them apart.
    def head_dim(key, idx):
        v = md.get("%s.attention.%s" % (arch, key))
        if v is not None and not isinstance(v, _Array):
            return int(v)
        if n_head[idx] == 0:
            raise GgufError("head_count is zero and no attention.%s to fall "
                            "back on" % key)
        return n_embd // n_head[idx]

    k_elems = sum(head_dim("key_length", i) * n_head_kv[i]
                  for i in range(n_layer))
    v_elems = sum(head_dim("value_length", i) * n_head_kv[i]
                  for i in range(n_layer))

    caveat = _CAVEATS.get(arch, "")
    # A sliding-window model allocates the window, not the whole context, for
    # its SWA layers, so the sum above is an upper bound rather than the number.
    swa = md.get("%s.attention.sliding_window" % arch)
    if not caveat and swa is not None and not isinstance(swa, _Array):
        caveat = ("this model uses sliding-window attention (window %d), whose "
                  "cache stops growing at the window - the real cache is "
                  "smaller" % int(swa))

    n_vocab = 0
    tokens = md.get("tokenizer.ggml.tokens")
    if isinstance(tokens, _Array):
        n_vocab = tokens.length
    if not n_vocab:
        n_vocab = int(md.get("%s.vocab_size" % arch, 0) or 0)

    return {
        "ARCH": arch,
        "N_LAYER": n_layer,
        "N_EMBD": n_embd,
        "N_HEAD": n_head[0],
        "N_HEAD_KV": n_head_kv[0],
        "N_CTX_TRAIN": _int(md, "%s.context_length" % arch, 0),
        "N_VOCAB": n_vocab,
        "K_ELEMS_PER_TOKEN": k_elems,
        "V_ELEMS_PER_TOKEN": v_elems,
        "ESTIMATE_CAVEAT": caveat,
    }


_SAFE = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: gguf.py <file.gguf>\n")
        return 2
    try:
        info = describe(argv[1])
    except GgufError as e:
        sys.stderr.write("%s\n" % e)
        return 2
    except OSError as e:
        sys.stderr.write("cannot read %s: %s\n" % (argv[1], e.strerror))
        return 2
    # Built whole, then written once: a caller that reads stdout and stderr into
    # the same string must be able to tell a reason from a half-finished answer.
    out = []
    for key, val in info.items():
        if isinstance(val, str):
            # The caveat is a sentence, and every other string comes from the
            # file - so quote, and refuse rather than emit anything that could
            # end the quote. The caller evals this.
            if "'" in val or "\n" in val:
                val = val.replace("'", "").replace("\n", " ")
            if key != "ESTIMATE_CAVEAT" and not set(val) <= _SAFE:
                sys.stderr.write("%s in the metadata is not a plain token\n" % key)
                return 2
            out.append("GGUF_%s='%s'" % (key, val))
        else:
            out.append("GGUF_%s=%d" % (key, val))
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
