#!/usr/bin/env bash
set -euo pipefail
# Snakemake copies this hook beside its hashed environment: keep it standalone.
# No GPU or CheckM reference database is required until an analysis job runs.
: "${CONDA_PREFIX:?Snakemake must activate the managed Conda environment}"
python -I - "$CONDA_PREFIX" <<'PY'
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

VERSION = "1.1.0"
SOURCE_URL = "https://github.com/ziyewang/COMEBin/archive/refs/tags/1.1.0.tar.gz"
TORCH_URL = (
    "https://download-r2.pytorch.org/whl/cu126/"
    "torch-2.13.0%2Bcu126-cp311-cp311-manylinux_2_28_x86_64.whl"
)
REQUIRED = (
    "COMEBin/run_comebin.sh", "COMEBin/main.py",
    "auxiliary/bacar_marker.hmm", "auxiliary/marker.hmm",
    "auxiliary/test_getmarker_2quarter.pl",
)


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


def extract_source(archive, destination):
    root_name = "COMEBin-" + VERSION
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or path.parts[0] != root_name:
                raise RuntimeError("Unsafe path in COMEBin source archive: " + member.name)
            if not (member.isfile() or member.isdir()):
                raise RuntimeError("Unexpected non-file member in COMEBin source archive")
        # The source archive contains only files and directories.
        source.extractall(destination, filter="data")
    root = destination / root_name
    for relative in REQUIRED:
        path = root / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError("COMEBin release is missing required data: " + relative)
    return root


def write_constraints(destination):
    versions = {}
    for distribution in importlib.metadata.distributions():
        name = distribution.metadata.get("Name", "")
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            versions[name] = distribution.version
    destination.write_text("".join(f"{name}=={version}\n" for name, version in sorted(versions.items())))


def main():
    prefix = Path(sys.argv[1]).resolve()
    if Path(sys.prefix).resolve() != prefix:
        raise RuntimeError("Refusing to install outside the active Conda environment")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("The managed COMEBin environment requires Linux x86_64")
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("The pinned COMEBin/PyTorch environment requires Python 3.11")
    libc_name, libc_version = platform.libc_ver()
    if libc_name != "glibc" or tuple(map(int, libc_version.split(".")[:2])) < (2, 28):
        raise RuntimeError("The pinned PyTorch CUDA wheel requires glibc >=2.28")
    share = prefix / "share"
    share.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="comebin-install-", dir=share) as temporary:
        work = Path(temporary)
        archive = work / "COMEBin-1.1.0.tar.gz"
        download(SOURCE_URL, archive)
        extracted = extract_source(archive, work)
        constraints = work / "conda-packages.txt"
        write_constraints(constraints)
        subprocess.run([
            sys.executable, "-I", "-m", "pip", "--isolated", "install", "--no-input",
            "--only-binary=:all:", "--index-url", "https://download.pytorch.org/whl/cu126",
            "--constraint", str(constraints), TORCH_URL,
        ], check=True)
        if importlib.metadata.version("torch") != "2.13.0+cu126":
            raise RuntimeError("The installed PyTorch does not match the pinned CUDA build")
        destination = share / ("comebin-" + VERSION)
        if destination.exists():
            raise RuntimeError("COMEBin installation destination already exists: " + str(destination))
        os.replace(extracted, destination)
        executable = destination / "COMEBin/run_comebin.sh"
        executable.chmod(executable.stat().st_mode | 0o111)
        link = prefix / "bin/run_comebin.sh"
        link.symlink_to(Path("../share") / destination.name / "COMEBin/run_comebin.sh")
        # -V exits before Python imports, CheckM database lookup, or GPU use.
        subprocess.run([str(link), "-V"], check=True)
        (destination / "installation.json").write_text(json.dumps({
            "version": VERSION, "source_url": SOURCE_URL,
            "torch_url": TORCH_URL,
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
PY
