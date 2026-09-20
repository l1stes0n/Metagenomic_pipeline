#!/usr/bin/env bash
set -euo pipefail
# Standalone: Snakemake copies this file into its environment cache.
# Do not import CuPy or require a GPU while preparing environments on a login node.
: "${CONDA_PREFIX:?Snakemake must activate the managed Conda environment}"
python -I - "$CONDA_PREFIX" <<'PY'
import importlib.metadata
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

VERSION = "1.0.6"
WHEEL_URL = "https://github.com/liu-congcong/MetaCAT/releases/download/v1.0.6/metacat-1.0.6-py3-none-any.whl"


def download(url, destination):
    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "metagenomic-snakemake/1"})
            with urllib.request.urlopen(request, timeout=120) as source, destination.open("wb") as out:
                shutil.copyfileobj(source, out)
            break
        except (OSError, urllib.error.URLError):
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def main():
    prefix = Path(sys.argv[1]).resolve()
    if Path(sys.prefix).resolve() != prefix:
        raise RuntimeError("Refusing to install outside the active Conda environment")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("The managed MetaCAT environment requires Linux x86_64")
    with tempfile.TemporaryDirectory(prefix="metacat-install-", dir=prefix) as temporary:
        wheel = Path(temporary) / "metacat-1.0.6-py3-none-any.whl"
        download(WHEEL_URL, wheel)
        subprocess.run([
            sys.executable, "-I", "-m", "pip", "--isolated", "install", "--no-input",
            "--no-deps", str(wheel),
        ], check=True)
    distribution = importlib.metadata.distribution("MetaCAT")
    if distribution.version != VERSION:
        raise RuntimeError("MetaCAT installation version does not match the pinned release")
    for relative in (
        "MetaCAT/markers.gz", "MetaCAT/FragGeneScan-linux-x86_64",
        "MetaCAT/hmmsearch-linux-x86_64", "MetaCAT/train/complete",
    ):
        path = Path(distribution.locate_file(relative))
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("MetaCAT wheel is missing bundled marker data or binary: " + relative)
        if relative.endswith("linux-x86_64"):
            path.chmod(path.stat().st_mode | 0o111)
    if not (prefix / "bin/MetaCAT").is_file():
        raise RuntimeError("MetaCAT console entry point was not installed")
    manifest = prefix / "share/metacat-installation.json"
    manifest.parent.mkdir(exist_ok=True)
    manifest.write_text(json.dumps({
        "version": VERSION, "wheel_url": WHEEL_URL,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
PY
