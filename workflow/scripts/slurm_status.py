#!/usr/bin/env python3
"""Report running/success/failed to the Snakemake cluster-generic executor.

Success requires a COMPLETED allocation with ExitCode 0:0 in sacct. A missing
job is never success: squeue and accounting can be briefly out of sync. After
five minutes without usable status, fail the status command with a diagnostic
instead of silently waiting forever or pretending the scientific job failed.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import time


UNKNOWN_GRACE_SECONDS = 300
QUERY_TIMEOUT_SECONDS = 15
RUNNING_STATES = {
    "PENDING", "RUNNING", "SUSPENDED", "COMPLETING", "CONFIGURING",
    "EXPEDITING", "POWER_UP_NODE", "REQUEUED", "REQUEUE_FED", "REQUEUE_HOLD",
    "RESIZING", "RESV_DEL_HOLD", "SIGNALING", "SPECIAL_EXIT", "STAGE_OUT",
    "STOPPED", "UPDATE_DB",
}
FAILED_STATES = {
    "BOOT_FAIL", "CANCELLED", "DEADLINE", "FAILED", "NODE_FAIL",
    "OUT_OF_MEMORY", "PREEMPTED", "REVOKED", "LAUNCH_FAILED", "RECONFIG_FAIL", "TIMEOUT",
}


def split_job_id(external_id):
    match = re.fullmatch(r"([1-9][0-9]*)(?:;([A-Za-z0-9_.-]+))?", external_id)
    if match is None:
        raise ValueError(f"Invalid Slurm job ID: {external_id!r}")
    return match.group(1), match.group(2)


def unknown_path(external_id, state_dir=None):
    split_job_id(external_id)
    root = Path(state_dir) if state_dir is not None else Path(".snakemake/slurm-status")
    return root / (external_id.replace(";", "_") + ".unknown")


def clear_unknown(external_id, state_dir=None):
    unknown_path(external_id, state_dir).unlink(missing_ok=True)


def normalize_state(value):
    # sacct may append a truncation marker or " by <uid>" to CANCELLED.
    tokens = value.strip().split()
    return tokens[0].rstrip("+").upper() if tokens else ""


def query(command):
    # Command-line output format overrides the usual Slurm format variables.
    # Drop client options that could silently filter or redirect these queries.
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("SQUEUE_", "SACCT_"))
        and key != "SLURM_CLUSTERS"
    }
    try:
        result = subprocess.run(
            command, text=True, capture_output=True, check=False,
            timeout=QUERY_TIMEOUT_SECONDS, env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    if result.returncode:
        return None, result.stderr.strip() or f"{command[0]} exit code {result.returncode}"
    return result.stdout, ""


def unresolved(external_id, diagnostics, state_dir=None, now=None):
    now = time.time() if now is None else now
    marker = unknown_path(external_id, state_dir)
    marker.parent.mkdir(parents=True, exist_ok=True)
    try:
        first_missing = float(marker.read_text())
    except FileNotFoundError:
        marker.write_text(str(now))
        first_missing = now
    except ValueError as error:
        raise RuntimeError(f"Invalid status cache: {marker}; inspect/remove this file") from error
    if now - first_missing >= UNKNOWN_GRACE_SECONDS:
        raise RuntimeError(
            f"No reliable Slurm status for {external_id} for at least "
            f"{UNKNOWN_GRACE_SECONDS} s. Check squeue/sacct and accounting availability. "
            + "; ".join(diagnostics)
        )
    return "running"


def get_status(external_id, state_dir=None, now=None):
    job_id, cluster = split_job_id(external_id)
    cluster_args = [f"--clusters={cluster}"] if cluster else []
    queue_output, queue_error = query([
        "squeue", "--noheader", f"--jobs={job_id}", "--format=%i|%T", *cluster_args,
    ])
    diagnostics = [queue_error] if queue_error else []
    if queue_output is not None:
        for line in queue_output.splitlines():
            fields = line.strip().split("|")
            if len(fields) != 2 or fields[0].strip() != job_id:
                continue
            state = normalize_state(fields[1])
            # The live controller wins over stale sacct records after requeue.
            if state in RUNNING_STATES:
                clear_unknown(external_id, state_dir)
                return "running"
            if state in FAILED_STATES:
                clear_unknown(external_id, state_dir)
                return "failed"

    accounting_output, accounting_error = query([
        "sacct", "--noheader", "--parsable2", "--allocations",
        f"--jobs={job_id}", "--format=JobIDRaw,State%40,ExitCode", *cluster_args,
    ])
    if accounting_error:
        diagnostics.append(accounting_error)
    if accounting_output is not None:
        rows = []
        for line in accounting_output.splitlines():
            fields = [field.strip() for field in line.strip().split("|")]
            # Match the allocation exactly; never infer success from .batch,
            # .extern, or a different job's successful step.
            if len(fields) == 3 and fields[0] == job_id:
                rows.append((normalize_state(fields[1]), fields[2]))
        if len(rows) == 1:
            state, exit_code = rows[0]
            if state in RUNNING_STATES:
                clear_unknown(external_id, state_dir)
                return "running"
            if state in FAILED_STATES:
                clear_unknown(external_id, state_dir)
                return "failed"
            if state == "COMPLETED" and re.fullmatch(r"[0-9]+:[0-9]+", exit_code):
                clear_unknown(external_id, state_dir)
                return "success" if exit_code == "0:0" else "failed"
        diagnostics.append(f"sacct did not return one usable allocation record for {job_id}")
    return unresolved(external_id, diagnostics, state_dir, now)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job_id")
    args = parser.parse_args()
    try:
        status = get_status(args.job_id)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Slurm status error: {error}", file=sys.stderr)
        return 1
    print(status)
    return 0


if __name__ == "__main__":
    sys.exit(main())
