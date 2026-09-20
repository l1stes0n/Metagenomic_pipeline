#!/usr/bin/env python3
"""Record executable availability in the environment activated by Snakemake."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil


def inspect_environment(executables, environ=None):
    environ = os.environ if environ is None else environ
    prefix = environ.get("CONDA_PREFIX")
    if not prefix:
        raise ValueError("No activated Conda environment. Use --software-deployment-method conda.")
    prefix = Path(prefix).resolve()
    commands = {}
    for name in executables:
        command = shutil.which(name, path=environ.get("PATH", ""))
        if command is None:
            raise ValueError(f"Missing required command in environment {prefix}: {name}")
        # Do not silently accept a tool inherited from the login-node PATH.
        location = Path(command).parent.resolve() / Path(command).name
        if not location.is_relative_to(prefix):
            raise ValueError(f"{name} resolved outside the selected environment: {command}")
        commands[name] = command
    return str(prefix), commands


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--specification", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--executables", nargs="+", required=True)
    args = parser.parse_args()
    prefix, commands = inspect_environment(args.executables)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "tool": args.tool, "specification": args.specification,
        "prefix": prefix, "executables": commands,
        "verification": "executable_availability_only; GPU and real-data runs not exercised",
        "checked_at": datetime.now(timezone.utc).isoformat(),
    }, indent=2) + "\n")
    print(f"Ready: {args.tool}: {prefix}")


if __name__ == "__main__":
    main()
