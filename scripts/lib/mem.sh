# lib/mem.sh - What the configured deployment will actually ask the board for.
#
# Sourced by validate.sh. The question it answers is the one an 8 GB Jetson
# makes unavoidable: the weights are not the footprint. A 1.8 GiB model at
# CTX_SIZE=16384 with a q8_0 KV cache asks for another 306 MiB of cache on top,
# and the compute buffers scale with the vocabulary, not with the weights. A
# check that compares the *file size* against the budget - which is what this
# repo did until now - passes for a configuration the board cannot run, and the
# failure arrives later, as a container that loaded, reported healthy, and then
# died with a cudaMalloc error once the cache filled.
#
# Everything here is either exact or measured. The KV cache is computed from the
# model's own metadata with ggml's block sizes, and validate.sh checks that
# prediction against the size llama.cpp reports in its log on every runtime run
# - so the estimate cannot quietly drift away from what the server does. The
# compute buffers are *not* estimated: their size depends on the build, so they
# are reported from the log rather than guessed at, and the preflight check
# states how much of the budget is left for them instead of pretending to know.

# ggml type sizes, as (bytes per block / elements per block). Integer pairs
# rather than a float: q8_0 is 34 bytes per 32 elements, and 1.0625 written as
# a bash-friendly number is a rounding error waiting to be an off-by-a-few-MiB
# in a report whose whole point is that it agrees with llama.cpp exactly.
declare -gA MEM_TYPE_SIZE=(
  [f32]=4 [f16]=2 [bf16]=2
  [q8_0]=34 [q8_1]=36
  [q5_0]=22 [q5_1]=24
  [q4_0]=18 [q4_1]=20
  [iq4_nl]=18
)
declare -gA MEM_BLCK_SIZE=(
  [f32]=1 [f16]=1 [bf16]=1
  [q8_0]=32 [q8_1]=32
  [q5_0]=32 [q5_1]=32
  [q4_0]=32 [q4_1]=32
  [iq4_nl]=32
)

# mem_type_known TYPE - rc=0 when this is a KV cache type we can size.
mem_type_known() {
  local t="${1,,}"
  [[ -n "${MEM_TYPE_SIZE[$t]+x}" ]]
}

# mem_kv_bytes N_CTX K_ELEMS V_ELEMS TYPE_K TYPE_V - print the bytes llama.cpp
# will allocate for the KV cache, or rc=2 with a reason on stderr.
#
# K_ELEMS/V_ELEMS are per-token element counts already summed over layers (what
# gguf.py emits), so an architecture with a different KV head count per layer is
# handled by the same arithmetic. n_ctx is llama.cpp's *total* context across
# slots - `--parallel N` divides it, it does not multiply it - which is why
# PARALLEL does not appear here.
mem_kv_bytes() {
  local n_ctx="$1" k_elems="$2" v_elems="$3" tk="${4,,}" tv="${5,,}"
  local t
  for t in "$tk" "$tv"; do
    mem_type_known "$t" || { printf 'unknown KV cache type: %s' "$t" >&2; return 2; }
  done
  # llama.cpp rounds the cache up to a multiple of 256 tokens (GGML_PAD), so a
  # CTX_SIZE of 4000 allocates 4096 tokens' worth. Match it, or the differential
  # check against the log fails for a reason that is not a defect.
  local padded=$(( (n_ctx + 255) / 256 * 256 ))
  local kb=$(( padded * k_elems * MEM_TYPE_SIZE[$tk] / MEM_BLCK_SIZE[$tk] ))
  local vb=$(( padded * v_elems * MEM_TYPE_SIZE[$tv] / MEM_BLCK_SIZE[$tv] ))
  printf '%d' $(( kb + vb ))
}

# mem_max_ctx BYTES_AVAILABLE K_ELEMS V_ELEMS TYPE_K TYPE_V - the largest
# CTX_SIZE whose cache fits in BYTES_AVAILABLE, rounded down to 256 tokens.
# This is what makes a failure message actionable: "lower CTX_SIZE" is advice,
# "CTX_SIZE=8192 fits, 16384 does not" is an instruction.
mem_max_ctx() {
  local avail="$1" k_elems="$2" v_elems="$3" tk="${4,,}" tv="${5,,}"
  mem_type_known "$tk" && mem_type_known "$tv" || return 2
  local per_token=$(( k_elems * MEM_TYPE_SIZE[$tk] / MEM_BLCK_SIZE[$tk]
                    + v_elems * MEM_TYPE_SIZE[$tv] / MEM_BLCK_SIZE[$tv] ))
  (( per_token > 0 )) || return 2
  local n=$(( avail / per_token / 256 * 256 ))
  (( n < 0 )) && n=0
  printf '%d' "$n"
}

# mem_model_read FILE - print the GGUF_* assignments for FILE, rc=2 with the
# reader's own reason on stderr. Split out so a caller can report *why* it
# cannot size a model rather than silently skipping the check.
#
# The reader is python3, which validate.sh already requires and checks for. Its
# output is eval-safe by contract (see lib/gguf.py); it is still not sourced
# into the caller's shell here, so a caller decides when to eval.
mem_model_read() {
  local lib="${MEM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
  local py="${MEM_PYTHON:-python3}"
  command -v "$py" >/dev/null 2>&1 || {
    printf 'python3 is needed to read the model metadata' >&2; return 2; }
  "$py" "$lib/gguf.py" "$1"
}

# mem_mib BYTES - bytes as whole MiB, rounded to nearest so a report that says
# 306 MiB agrees with a log that says 306.03 MiB.
mem_mib() { printf '%d' $(( ($1 + 524288) / 1048576 )); }
