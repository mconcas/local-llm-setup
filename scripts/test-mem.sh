#!/usr/bin/env bash
# test-mem.sh - Hermetic tests for lib/mem.sh and lib/gguf.py, the memory sizing
# the validation suite refuses configurations on.
#
# Sizing is the one part of this repo whose answer is a number rather than a
# verdict, and a number that nothing contradicts is a belief. Two things pin it:
#
#   this suite      the arithmetic, against values computed by hand, and the
#                   metadata reader, against files whose contents it wrote
#   validate.sh     the prediction, against the size llama.cpp reports having
#                   allocated - on every runtime run, on real hardware
#
# The second is why the first can be blunt about failure: if the formula drifts
# from what the server does, the runtime check goes red rather than the suite
# quietly agreeing with itself.
#
# Everything a Jetson cannot demonstrate is here: a 70B at a 128k context, a
# sliding-window model whose cache stops growing, an architecture whose KV head
# count varies by layer, a cache type llama.cpp does not quantize to, a file
# truncated inside its own metadata. The fixtures are sparse, so a "7 GiB model"
# costs a few KiB - the same constraint the real models are under.
#
# Needs no GPU, Docker, model, network or daemon; python3 only.
#
# Usage:
#   ./scripts/test-mem.sh          # run all cases
#   ./scripts/test-mem.sh -v       # also print each assertion
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MKGGUF="$SCRIPT_DIR/test-fixtures/mkgguf.py"

VERBOSE=0
[[ "${1:-}" == "-v" || "${1:-}" == "--verbose" ]] && VERBOSE=1

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_SK=$'\033[33m'; C_HD=$'\033[1m'; C_Z=$'\033[0m'
else
  C_OK=""; C_NO=""; C_SK=""; C_HD=""; C_Z=""
fi

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()
CASE=""

pass() { PASS=$((PASS+1)); (( VERBOSE )) && printf '  %sok%s   %s\n' "$C_OK" "$C_Z" "$1"; return 0; }
fail() {
  FAIL=$((FAIL+1)); FAILED_NAMES+=("$CASE: $1")
  printf '  %sFAIL%s %s\n' "$C_NO" "$C_Z" "$1"
  [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
  return 0
}
skipped() { SKIP=$((SKIP+1)); printf '  %sskip%s %s\n' "$C_SK" "$C_Z" "$1"; return 0; }
case_start() { CASE="$1"; printf '\n%s%s%s\n' "$C_HD" "$1" "$C_Z"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
assert_has() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "no [$2] in [$3]"; fi
}
assert_rc() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected rc $2, got $3"; fi
}

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 2; }

# The library under test is sourced into this shell.
. "$SCRIPT_DIR/lib/mem.sh"

# gguf OUT [mkgguf args...] - build a fixture model, print its path.
gguf() {
  local out="$TMPROOT/$1"; shift
  python3 "$MKGGUF" "$out" "$@" || return 1
  printf '%s' "$out"
}

# read_gguf FILE - the reader's output as a single string, stderr included.
read_gguf() { mem_model_read "$1" 2>&1; }

# ══════════════════════════════════════════════════════════════════
case_start "The KV cache arithmetic, against numbers computed by hand"
# ══════════════════════════════════════════════════════════════════
# A worked example, so a future reader can check the formula rather than trust
# it: Qwen2.5 3B has 36 layers, 2 KV heads and a head dimension of 2048/16=128,
# so 36 * 2 * 128 = 9216 elements per token for K and the same for V. At q8_0,
# ggml stores 32 elements in 34 bytes. 16384 tokens is therefore
#   16384 * (9216 * 34/32) * 2 = 320864256 bytes = 306 MiB
# and llama.cpp on the Orin Nano Super reports "KV buffer size = 306.03 MiB".
assert_eq "q8_0 K and V at 16384 tokens" "320864256" "$(mem_kv_bytes 16384 9216 9216 q8_0 q8_0)"
assert_eq "…rendered as whole MiB" "306" "$(mem_mib "$(mem_kv_bytes 16384 9216 9216 q8_0 q8_0)")"
# f16 is 2 bytes per element flat, so exactly 32/34ths more than q8_0 - the
# reason the Jetson defaults recommend q8_0 at all.
assert_eq "f16 K and V at 16384 tokens" "603979776" "$(mem_kv_bytes 16384 9216 9216 f16 f16)"
assert_eq "…rendered as whole MiB" "576" "$(mem_mib "$(mem_kv_bytes 16384 9216 9216 f16 f16)")"
# Mixed types are legal and were recorded as one value until iteration 12; the
# arithmetic has to keep them apart or a q8_0/f16 run sizes as q8_0/q8_0.
assert_eq "q8_0 K with f16 V is between the two" "462422016" "$(mem_kv_bytes 16384 9216 9216 q8_0 f16)"
# K and V need not have the same element count (DeepSeek, some MoE models), and
# a single "head dim" would average them into a number that is wrong both ways.
assert_eq "asymmetric element counts are added, not averaged" "4096" "$(mem_kv_bytes 256 2 6 f16 f16)"

# llama.cpp rounds the cache up to a multiple of 256 tokens, so a CTX_SIZE that
# is not one still allocates the padded size. Predicting the unpadded number
# would fail the runtime differential check for a reason that is not a defect.
assert_eq "4000 tokens allocates 4096" \
  "$(mem_kv_bytes 4096 9216 9216 q8_0 q8_0)" "$(mem_kv_bytes 4000 9216 9216 q8_0 q8_0)"
assert_eq "an exact multiple is not padded further" \
  "$(mem_kv_bytes 4096 9216 9216 q8_0 q8_0)" "$(mem_kv_bytes 4096 9216 9216 q8_0 q8_0)"

# Every type ggml can quantize a KV cache to, with its block layout. A typo in
# this table is a silently wrong budget, so each is pinned at one known size.
assert_eq "f32 is 4 bytes per element"   "8192" "$(mem_kv_bytes 256 4 4 f32 f32)"
assert_eq "bf16 is 2 bytes per element"  "4096" "$(mem_kv_bytes 256 4 4 bf16 bf16)"
assert_eq "q8_1 is 36 bytes per 32"      "2304" "$(mem_kv_bytes 256 4 4 q8_1 q8_1)"
assert_eq "q5_0 is 22 bytes per 32"      "1408" "$(mem_kv_bytes 256 4 4 q5_0 q5_0)"
assert_eq "q5_1 is 24 bytes per 32"      "1536" "$(mem_kv_bytes 256 4 4 q5_1 q5_1)"
assert_eq "q4_0 is 18 bytes per 32"      "1152" "$(mem_kv_bytes 256 4 4 q4_0 q4_0)"
assert_eq "q4_1 is 20 bytes per 32"      "1280" "$(mem_kv_bytes 256 4 4 q4_1 q4_1)"
assert_eq "iq4_nl is 18 bytes per 32"    "1152" "$(mem_kv_bytes 256 4 4 iq4_nl iq4_nl)"
assert_eq "a cache type is case-insensitive" \
  "$(mem_kv_bytes 256 4 4 q8_0 q8_0)" "$(mem_kv_bytes 256 4 4 Q8_0 Q8_0)"

# A type llama.cpp does not quantize a cache to must be refused by name. The
# tempting alternative - fall back to f16 - produces a budget for a deployment
# that will not start, which is the failure this whole file exists to prevent.
out="$(mem_kv_bytes 4096 9216 9216 q3_k q8_0 2>&1)"; rc=$?
assert_rc "an unknown K type is an error" 2 "$rc"
assert_has "…and names the type" "q3_k" "$out"
out="$(mem_kv_bytes 4096 9216 9216 q8_0 q6_k 2>&1)"; rc=$?
assert_rc "an unknown V type is an error too" 2 "$rc"
assert_has "…and names that one" "q6_k" "$out"
assert_rc "an empty type is not silently f16" 2 "$(mem_kv_bytes 4096 9216 9216 '' q8_0 >/dev/null 2>&1; echo $?)"

# ══════════════════════════════════════════════════════════════════
case_start "The largest context that fits, which is what makes advice actionable"
# ══════════════════════════════════════════════════════════════════
# "Lower CTX_SIZE" is advice. "CTX_SIZE=8192 fits" is an instruction, and it is
# only worth printing if the number it names actually fits.
for want in 1024 4096 16384 65536; do
  bytes="$(mem_kv_bytes "$want" 9216 9216 q8_0 q8_0)"
  got="$(mem_max_ctx "$bytes" 9216 9216 q8_0 q8_0)"
  assert_eq "the largest context fitting a ${want}-token cache is ${want}" "$want" "$got"
done
# The number it reports must fit, and one step up must not - the property that
# makes it safe to print as an instruction.
budget=$(( 700 * 1048576 ))
n="$(mem_max_ctx "$budget" 9216 9216 q8_0 q8_0)"
fits="$(mem_kv_bytes "$n" 9216 9216 q8_0 q8_0)"
over="$(mem_kv_bytes $(( n + 256 )) 9216 9216 q8_0 q8_0)"
if (( fits <= budget )); then pass "the suggested context fits the budget"
else fail "the suggested context fits the budget" "$fits > $budget"; fi
if (( over > budget )); then pass "one step larger does not"
else fail "one step larger does not" "$over <= $budget"; fi
assert_eq "the suggestion is a multiple of 256" "0" "$(( n % 256 ))"
assert_eq "a budget too small for one block is 0" "0" "$(mem_max_ctx 16 9216 9216 q8_0 q8_0)"
assert_eq "a negative budget is 0, not a negative context" "0" "$(mem_max_ctx -1 9216 9216 q8_0 q8_0)"
# A cheaper cache type must never suggest a smaller context than a dearer one.
q="$(mem_max_ctx "$budget" 9216 9216 q8_0 q8_0)"
f="$(mem_max_ctx "$budget" 9216 9216 f16 f16)"
if (( q > f )); then pass "q8_0 allows a longer context than f16"
else fail "q8_0 allows a longer context than f16" "q8_0=$q f16=$f"; fi

assert_eq "mem_mib rounds to nearest, not down" "1" "$(mem_mib 524289)"
assert_eq "…and 0.4 MiB is 0" "0" "$(mem_mib 419430)"

# ══════════════════════════════════════════════════════════════════
case_start "Reading the fields out of a real GGUF"
# ══════════════════════════════════════════════════════════════════
M="$(gguf q3b.gguf --arch qwen2 --layers 36 --embd 2048 --heads 16 --kv-heads 2 \
     --ctx-train 32768 --vocab 4096 --size-mib 64)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "a well-formed GGUF is read" 0 "$rc"
assert_has "the architecture"        "GGUF_ARCH='qwen2'"        "$out"
assert_has "the layer count"         "GGUF_N_LAYER=36"          "$out"
assert_has "the embedding length"    "GGUF_N_EMBD=2048"         "$out"
assert_has "the KV head count"       "GGUF_N_HEAD_KV=2"         "$out"
assert_has "the trained context"     "GGUF_N_CTX_TRAIN=32768"   "$out"
assert_has "the vocabulary size"     "GGUF_N_VOCAB=4096"        "$out"
assert_has "K elements per token"    "GGUF_K_ELEMS_PER_TOKEN=9216" "$out"
assert_has "V elements per token"    "GGUF_V_ELEMS_PER_TOKEN=9216" "$out"
assert_has "no caveat on an ordinary model" "GGUF_ESTIMATE_CAVEAT=''" "$out"

# The output is eval'd by validate.sh, so it has to survive that intact - the
# same contract detect-platform.sh --env has, and the same one an emitted value
# containing a quote would break.
( set -u; eval "$out"; [[ "$GGUF_N_LAYER" == 36 && "$GGUF_ARCH" == qwen2 ]] )
assert_rc "the output is eval-safe" 0 "$?"
lines="$(grep -c . <<<"$out")"
assert_eq "one field per line, ten fields" "10" "$lines"

# The vocabulary is a 150k-entry array in a real file, and only its length is
# used. Reading it as data rather than skipping it is the difference between a
# check that costs half a second and one that costs a minute.
BIG="$(gguf big-vocab.gguf --vocab 151936 --size-mib 8)"
start=$SECONDS
out="$(read_gguf "$BIG")"
assert_has "a 151936-token vocabulary is counted" "GGUF_N_VOCAB=151936" "$out"
if (( SECONDS - start <= 5 )); then pass "…without materialising it"
else fail "…without materialising it" "took $((SECONDS - start))s"; fi

# Only the metadata is read, so a model larger than the board's whole memory
# costs nothing to size. This is what lets the oversized cases below exist.
HUGE="$(gguf huge.gguf --layers 80 --embd 8192 --heads 64 --kv-heads 8 --size-mib 40000)"
disk_kb="$(du -k "$HUGE" | cut -f1)"
if (( disk_kb < 4096 )); then pass "a 40 GiB fixture costs under 4 MiB of disk"
else fail "a 40 GiB fixture costs under 4 MiB of disk" "${disk_kb} KiB"; fi
out="$(read_gguf "$HUGE")"
assert_has "…and is still read correctly" "GGUF_N_LAYER=80" "$out"

# ══════════════════════════════════════════════════════════════════
case_start "Head geometry the simple formula gets wrong"
# ══════════════════════════════════════════════════════════════════
# No GQA: head_count_kv absent means one KV head per attention head, not zero.
# The zero reading is the dangerous one - it sizes the cache at nothing.
M="$(gguf mha.gguf --layers 4 --embd 512 --heads 8 --omit qwen2.attention.head_count_kv)"
out="$(read_gguf "$M")"
assert_has "no head_count_kv means one KV head per Q head" "GGUF_K_ELEMS_PER_TOKEN=2048" "$out"

# key_length / value_length override n_embd/n_head and need not be equal, which
# a single "head dim" variable would silently make so.
M="$(gguf sepkv.gguf --layers 2 --embd 512 --heads 8 --kv-heads 2 --key-length 192 --value-length 128)"
out="$(read_gguf "$M")"
assert_has "an explicit key_length is used"   "GGUF_K_ELEMS_PER_TOKEN=768" "$out"
assert_has "and value_length separately"      "GGUF_V_ELEMS_PER_TOKEN=512" "$out"

# A KV head count that varies by layer is exactly the file a per-model scalar
# gets wrong, and the error is not small: here the mean is 3.75 heads, so a
# reader that took the first layer's 1 would size the cache at 27% of what it
# needs, and the container would die partway through a long prompt.
M="$(gguf perlayer.gguf --layers 4 --embd 512 --heads 8 --kv-heads-per-layer 1,2,4,8)"
out="$(read_gguf "$M")"
assert_has "per-layer KV heads are summed, not sampled" "GGUF_K_ELEMS_PER_TOKEN=960" "$out"
# A short array is extended with its last entry rather than being read as an
# empty tail, which would size the missing layers at nothing.
M="$(gguf shortarr.gguf --layers 4 --embd 512 --heads 8 --kv-heads-per-layer 2,2)"
out="$(read_gguf "$M")"
assert_has "a short per-layer array does not lose the remaining layers" \
  "GGUF_K_ELEMS_PER_TOKEN=512" "$out"

# ══════════════════════════════════════════════════════════════════
case_start "Models whose cache this arithmetic overestimates"
# ══════════════════════════════════════════════════════════════════
# A sliding-window model stops growing its cache at the window, so the sum over
# the full context is an upper bound. Reporting it as *the* number would refuse
# a configuration that fits - so it is reported, with the reason, as a bound.
M="$(gguf swa.gguf --arch gemma3 --layers 4 --embd 512 --heads 8 --kv-heads 4 --sliding-window 1024)"
out="$(read_gguf "$M")"
assert_has "sliding-window attention is flagged" "sliding-window attention" "$out"
assert_has "…and the window is named"            "window 1024"              "$out"
assert_has "…while the bound is still computed"  "GGUF_K_ELEMS_PER_TOKEN=1024" "$out"

# MLA caches a latent vector rather than per-head K and V, so this formula is
# wrong for it in the safe direction. Named rather than lumped into "unknown":
# "we do not model this architecture" is a more useful answer than a number.
M="$(gguf mla.gguf --arch deepseek2 --layers 4 --embd 512 --heads 8 --kv-heads 8)"
out="$(read_gguf "$M")"
assert_has "an MLA architecture is flagged" "MLA" "$out"
assert_has "…with the direction of the error stated" "smaller" "$out"

# ══════════════════════════════════════════════════════════════════
case_start "Files that cannot be sized, which must not read as zero"
# ══════════════════════════════════════════════════════════════════
# Every case here would size a cache at 0 bytes under a reader that returned
# defaults, and 0 bytes always fits.
printf 'not a model at all' >"$TMPROOT/plain.txt"
out="$(read_gguf "$TMPROOT/plain.txt")"; rc=$?
assert_rc "a non-GGUF file is an error" 2 "$rc"
assert_has "…naming the magic bytes" "magic" "$out"

# The shape iteration 8 found in download-model.sh: the magic bytes are the
# first thing to arrive, so a transfer cut off early still has them.
M="$(gguf cut.gguf --truncate-metadata)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "a file truncated inside its metadata is an error" 2 "$rc"
assert_has "…and says where it ended" "metadata" "$out"

printf 'GGUF\x03\x00\x00\x00' >"$TMPROOT/magiconly.gguf"
out="$(read_gguf "$TMPROOT/magiconly.gguf")"; rc=$?
assert_rc "magic bytes alone are not enough to size a model" 2 "$rc"

M="$(gguf v9.gguf --version 9)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "an unsupported GGUF version is an error" 2 "$rc"
assert_has "…naming the version" "version 9" "$out"

M="$(gguf noarch.gguf --omit general.architecture)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "a file with no architecture is an error" 2 "$rc"
assert_has "…saying which field" "architecture" "$out"

M="$(gguf nolayers.gguf --omit qwen2.block_count)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "a file with no block_count is an error" 2 "$rc"
assert_has "…saying which field" "block_count" "$out"

M="$(gguf noheads.gguf --omit qwen2.attention.head_count --omit qwen2.attention.head_count_kv)"
out="$(read_gguf "$M")"; rc=$?
assert_rc "a file with no head_count is an error" 2 "$rc"

out="$(read_gguf "$TMPROOT/does-not-exist.gguf")"; rc=$?
assert_rc "a missing file is an error" 2 "$rc"
assert_has "…naming the path" "does-not-exist" "$out"

# ══════════════════════════════════════════════════════════════════
case_start "Sizing the boards and models this one cannot hold"
# ══════════════════════════════════════════════════════════════════
# The point of the whole exercise: on 8 GB shared memory the weights are not the
# footprint, and the check this replaced could not see the difference.
#
# A 3B Q4_K_M is 1840 MiB. Against a 5571 MiB budget it is 33% - which the old
# file-size check reported as "leaves room for the KV cache" regardless of what
# CTX_SIZE said. Here is what CTX_SIZE actually costs for that model:
K=9216; V=9216
declare -A EXPECT=( [4096]=77 [16384]=306 [32768]=612 [131072]=2448 )
for ctx in 4096 16384 32768 131072; do
  mib="$(mem_mib "$(mem_kv_bytes "$ctx" $K $V q8_0 q8_0)")"
  assert_eq "a ${ctx}-token q8_0 cache for a 3B is ${EXPECT[$ctx]} MiB" "${EXPECT[$ctx]}" "$mib"
done
# 1840 + 2448 = 4288 MiB, 77% of the budget - past the point where the compute
# buffers still fit, and invisible to a check that only looks at the file.
tot=$(( 1840 + $(mem_mib "$(mem_kv_bytes 131072 $K $V q8_0 q8_0)") ))
if (( tot * 100 / 5571 > 75 )); then pass "a 3B at 131072 tokens is over the 75% line"
else fail "a 3B at 131072 tokens is over the 75% line" "${tot} MiB"; fi
if (( 1840 * 100 / 5571 <= 75 )); then pass "…while its weights alone are not"
else fail "…while its weights alone are not" ""; fi

# A 7B at f16 on the same board: the cache alone is more than the budget.
M="$(gguf b7.gguf --layers 32 --embd 4096 --heads 32 --kv-heads 8 --size-mib 4400)"
out="$(read_gguf "$M")"
eval "$out"
assert_eq "a 7B GQA model is 32768 KV elements per token" "32768" "$GGUF_K_ELEMS_PER_TOKEN"
kv="$(mem_mib "$(mem_kv_bytes 32768 "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" f16 f16)")"
if (( 4400 + kv > 5571 )); then pass "its weights plus an f16 cache at 32768 tokens exceed the board"
else fail "its weights plus an f16 cache at 32768 tokens exceed the board" "4400 + ${kv} MiB"; fi
kvq="$(mem_mib "$(mem_kv_bytes 32768 "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0)")"
if (( kvq < kv )); then pass "quantizing the cache brings it down"
else fail "quantizing the cache brings it down" "q8_0=$kvq f16=$kv"; fi
# The advice the failure branch prints, for this model on this board. A 4400 MiB
# model on a 5571 MiB budget is already past the 75% line before the cache
# exists, so the honest answer is "none" - and the caller has to say so rather
# than print "CTX_SIZE=0 fits", which was what it did until this case was
# written.
fit="$(mem_max_ctx $(( (5571 * 75 / 100 - 4400) * 1048576 )) \
       "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0)"
assert_eq "a model with no room left for a cache suggests no context" "0" "$fit"
# The same model on a board with room does get a usable suggestion, and the
# suggestion is checked against the room it was derived from rather than against
# a number picked here - the assertion has to hold for any board size.
room=$(( (12000 * 75 / 100 - 4400) * 1048576 ))
fit="$(mem_max_ctx "$room" "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0)"
if (( fit > 0 )); then pass "a larger board suggests a usable context ($fit)"
else fail "a larger board suggests a usable context" "got $fit"; fi
if (( $(mem_kv_bytes "$fit" "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0) <= room ))
then pass "…that actually fits the room it was derived from"
else fail "…that actually fits the room it was derived from" "$fit"; fi

# Monotonicity, over the board sizes this repo recommends models for: a larger
# budget never suggests a shorter context, and a longer context never costs
# less. Property assertions rather than fixtures, because the boundaries that
# break sizing are the ones no enumerated case happens to sit on.
prev=0
for mib in 1500 2500 3500 5571 12000 28000; do
  n="$(mem_max_ctx $(( mib * 1048576 )) $K $V q8_0 q8_0)"
  if (( n >= prev )); then pass "a ${mib} MiB budget suggests at least as long a context"
  else fail "a ${mib} MiB budget suggests at least as long a context" "$n < $prev"; fi
  prev="$n"
done
prev=0
for ctx in 256 1024 4096 16384 65536 131072; do
  b="$(mem_kv_bytes "$ctx" $K $V q8_0 q8_0)"
  if (( b > prev )); then pass "a ${ctx}-token cache costs more than a shorter one"
  else fail "a ${ctx}-token cache costs more than a shorter one" "$b <= $prev"; fi
  prev="$b"
done

# ══════════════════════════════════════════════════════════════════
case_start "The repo's own model, sized against what llama.cpp allocated"
# ══════════════════════════════════════════════════════════════════
# The only non-hermetic case, and it is skipped when the model is not on disk.
# It exists because every number above is arithmetic over a file this suite
# wrote itself; this one reads the file the board actually serves.
REAL=""
for f in "$SCRIPT_DIR/../models"/*.gguf; do [[ -f "$f" ]] && REAL="$f" && break; done
if [[ -z "$REAL" ]]; then
  skipped "no model on disk to read (this case needs one, and downloads nothing)"
else
  out="$(read_gguf "$REAL")"; rc=$?
  assert_rc "the model on disk is readable" 0 "$rc"
  if (( rc == 0 )); then
    eval "$out"
    if (( GGUF_N_LAYER > 0 && GGUF_K_ELEMS_PER_TOKEN > 0 && GGUF_N_CTX_TRAIN > 0 )); then
      pass "…with a plausible geometry ($GGUF_ARCH, $GGUF_N_LAYER layers)"
    else
      fail "…with a plausible geometry" "$out"
    fi
    kv="$(mem_mib "$(mem_kv_bytes 16384 "$GGUF_K_ELEMS_PER_TOKEN" "$GGUF_V_ELEMS_PER_TOKEN" q8_0 q8_0)")"
    if (( kv > 0 )); then pass "…and a sizeable KV cache at 16384 tokens (${kv} MiB)"
    else fail "…and a sizeable KV cache at 16384 tokens" "$kv"; fi
  fi
fi

# ══════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "$C_HD" "$C_Z"
if (( FAIL == 0 )); then
  printf '%sAll %d assertions passed%s' "$C_OK" "$PASS" "$C_Z"
  (( SKIP )) && printf ' (%d skipped)' "$SKIP"
  printf '.\n'
  exit 0
fi
printf '%s%d of %d assertions failed%s:\n' "$C_NO" "$FAIL" "$((PASS+FAIL))" "$C_Z"
for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
exit 1
