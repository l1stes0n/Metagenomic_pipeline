#!/usr/bin/env bash
# Sourced inside Snakemake's Bash shell, after Conda activation.
limit_threads() {
    export OMP_NUM_THREADS="$1" OPENBLAS_NUM_THREADS="$1" MKL_NUM_THREADS="$1"
    export NUMEXPR_NUM_THREADS="$1" VECLIB_MAXIMUM_THREADS="$1" BLIS_NUM_THREADS="$1"
}

require_nonempty() {
    local file
    for file in "$@"; do
        [[ -s "$file" ]] || { echo "Missing or empty output: $file" >&2; return 1; }
    done
}
