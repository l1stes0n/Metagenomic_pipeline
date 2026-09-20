#!/usr/bin/env python3
"""Fail before GPU binning if the selected environment cannot use its allocation."""
import argparse
import os


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=("torch", "cupy"), required=True)
    args = parser.parse_args()
    try:
        if args.backend == "torch":
            import torch
            if not torch.cuda.is_available():
                raise RuntimeError("torch.cuda.is_available() is false")
            # Allocation detects driver/runtime incompatibility before training.
            torch.zeros(1, device="cuda")
            torch.cuda.synchronize()
        else:
            import cupy
            if cupy.cuda.runtime.getDeviceCount() < 1:
                raise RuntimeError("CuPy found no CUDA devices")
            cupy.zeros(1)
            cupy.cuda.runtime.deviceSynchronize()
    except Exception as error:
        raise SystemExit(
            f"CUDA preflight failed for {args.backend}: {error}. "
            f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')}. "
            "Check the GPU partition/allocation, driver compatibility and selected Conda environment."
        ) from error
    print(f"CUDA preflight passed: {args.backend}")


if __name__ == "__main__":
    main()
