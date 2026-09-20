#!/usr/bin/env python3
"""Cancel one or more validated Slurm job IDs supplied by cluster-generic."""

import argparse
from collections import defaultdict
import os
import subprocess
import sys

from slurm_status import split_job_id


def cancel(external_ids):
    jobs = defaultdict(list)
    for external_id in external_ids:
        job_id, cluster = split_job_id(external_id)
        jobs[cluster].append(job_id)
    # In particular, inherited SCANCEL_* options must not broaden cancellation.
    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith("SCANCEL_") and key != "SLURM_CLUSTERS"
    }
    failed = False
    for cluster, job_ids in jobs.items():
        command = ["scancel"]
        if cluster:
            command.append(f"--clusters={cluster}")
        result = subprocess.run(command + job_ids, env=env, check=False)
        failed = failed or result.returncode != 0
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("job_ids", nargs="+")
    args = parser.parse_args()
    try:
        return cancel(args.job_ids)
    except (OSError, ValueError) as error:
        print(f"Slurm cancellation error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
