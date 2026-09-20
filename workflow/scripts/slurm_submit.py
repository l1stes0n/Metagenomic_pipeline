#!/usr/bin/env python3
"""Submit one Snakemake job using an explicit, resource-limited Slurm interface.

The workflow working directory and environments must be shared by all nodes.
No user-provided sbatch options are interpolated or forwarded.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

from slurm_status import clear_unknown, split_job_id


def integer(value, name, minimum=1):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} must be an integer >= {minimum}; got {value!r}")
    return value


def submission_environment(environ):
    """Prevent sbatch defaults or an enclosing allocation from adding requests.

    Keep SLURM_CONF/SLURM_CONF_SERVER, which locate the cluster configuration.
    All SBATCH_* overrides and inherited SLURM allocation variables are removed.
    """
    return {
        key: value
        for key, value in environ.items()
        if not key.startswith("SBATCH_")
        and (not key.startswith("SLURM_") or key in {"SLURM_CONF", "SLURM_CONF_SERVER"})
    }


def build_command(properties, jobscript, workdir):
    threads = integer(properties.get("threads"), "Snakemake threads")
    resources = properties.get("resources", {})
    partition = resources.get("partition")
    if not isinstance(partition, str) or not re.fullmatch(
        r"[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*", partition
    ):
        raise ValueError("resources.partition must be a nonempty Slurm partition name/list")
    runtime = integer(resources.get("runtime"), "resources.runtime (minutes)")
    gpus = integer(resources.get("gpus", 0), "resources.gpus", minimum=0)
    account = resources.get("slurm_account", "")
    if account and (
        not isinstance(account, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", account)
    ):
        raise ValueError("resources.slurm_account must be a Slurm account name or empty")
    rule = re.sub(r"[^A-Za-z0-9_.-]", "_", str(properties.get("rule", "job")))[:80]
    job_number = re.sub(r"[^A-Za-z0-9_.-]", "_", str(properties.get("jobid", "0")))
    logdir = Path(workdir).resolve() / "logs" / "slurm"
    command = [
        "sbatch",
        "--parsable",
        "--nodes=1",
        "--ntasks=1",
        f"--cpus-per-task={threads}",
        f"--partition={partition}",
        f"--time={runtime}",
        f"--job-name=smk-{rule}-{job_number}",
        f"--chdir={Path(workdir).resolve()}",
        f"--output={logdir / (rule + '-%j.out')}",
        f"--error={logdir / (rule + '-%j.err')}",
    ]
    if account:
        command.append(f"--account={account}")
    if gpus:
        command.append(f"--gpus={gpus}")
    command.append(str(Path(jobscript).resolve()))
    return command


def submit(jobscript):
    # Import the supported Snakemake parser only on the submission path, allowing
    # status/cancellation and unit tests to use the Python standard library.
    from snakemake.utils import read_job_properties

    script = Path(jobscript).resolve(strict=True)
    # The standard Snakemake jobscript contains no SBATCH directives. Reject
    # custom directives so that they cannot bypass the resource whitelist.
    if any(line.lstrip().startswith("#SBATCH") for line in script.read_text().splitlines()):
        raise ValueError("Snakemake jobscript must not contain #SBATCH directives")
    properties = read_job_properties(str(script))
    command = build_command(properties, script, Path.cwd())
    (Path.cwd() / "logs" / "slurm").mkdir(parents=True, exist_ok=True)
    # Do not time out/retry sbatch automatically: after an ambiguous timeout the
    # scheduler may already have accepted a job, and a retry could duplicate it.
    result = subprocess.run(
        command,
        text=True,
        capture_output=True,
        env=submission_environment(os.environ),
        check=False,
    )
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr)
    if result.returncode:
        raise RuntimeError(f"sbatch failed with exit code {result.returncode}")
    external_id = result.stdout.strip()
    split_job_id(external_id)  # Validate before the plugin puts this in a shell command.
    try:
        clear_unknown(external_id)
    except OSError as error:
        # The scheduler has already accepted this job. Always return its ID so
        # Snakemake can track/cancel it, even if a stale local cache cannot clear.
        print(f"Could not clear status cache for {external_id}: {error}", file=sys.stderr)
    return external_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jobscript")
    args = parser.parse_args()
    try:
        external_id = submit(args.jobscript)
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        print(f"Slurm submission error: {error}", file=sys.stderr)
        return 1
    print(external_id)
    return 0


if __name__ == "__main__":
    sys.exit(main())
