#!/usr/bin/env python3
"""Resume and safely install pinned metagenomics reference archives.

Downloaded archives are retained under <database parent>/.downloads for reuse.
Existing mode is read-only and validates the required files.
"""

import argparse
from datetime import datetime, timezone
import hashlib
from http.client import IncompleteRead
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


NAMES = {"gtdbtk", "checkm", "checkm2"}
MANIFEST = ".database_manifest.json"
CHUNK = 8 * 1024 * 1024


def download(url, archive, attempts=4):
    """HTTP Range resume with overwrite if the server ignores Range.

    Network failures retain the .part file so a later attempt can resume.
    """
    archive = Path(archive)
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        return archive
    partial = archive.with_suffix(archive.suffix + ".part")
    for attempt in range(attempts):
        offset = partial.stat().st_size if partial.exists() else 0
        headers = {"User-Agent": "metagenomic-snakemake/1.0", "Accept-Encoding": "identity"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        try:
            with urlopen(Request(url, headers=headers), timeout=60) as response:
                status = response.status
                if status == 206:
                    match = re.fullmatch(r"bytes ([0-9]+)-([0-9]+)/([0-9]+|\*)", response.headers.get("Content-Range", ""))
                    if not match or int(match[1]) != offset:
                        raise ValueError("Download server returned an inconsistent Content-Range")
                    mode = "ab"
                else:
                    # Some mirrors ignore Range. Restart rather than corrupting
                    # the archive by appending a complete response to a prefix.
                    mode = "wb"
                with partial.open(mode) as handle:
                    shutil.copyfileobj(response, handle, length=CHUNK)
                if response.headers.get("Content-Length"):
                    expected_size = int(response.headers["Content-Length"]) + (offset if mode == "ab" else 0)
                    if partial.stat().st_size != expected_size:
                        raise URLError("Incomplete response; retaining partial download for resume")
            break
        except HTTPError as error:
            if error.code == 416 and partial.exists():
                break
            if attempt + 1 == attempts or error.code not in {408, 429, 500, 502, 503, 504}:
                raise
            time.sleep(min(2 ** attempt, 10))
        except (URLError, TimeoutError, ConnectionError, OSError, IncompleteRead):
            if attempt + 1 == attempts:
                raise
            time.sleep(min(2 ** attempt, 10))
    partial.replace(archive)
    return archive


def safe_extract(archive, destination):
    if not hasattr(tarfile, "data_filter"):
        raise RuntimeError("Safe archive extraction requires Python >=3.12 or patched Python >=3.11.8")
    destination = Path(destination).resolve()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise ValueError(f"Unsafe archive member: {member.name}")
            # Python's data filter rejects links outside destination and device
            # nodes while permitting ordinary links within the extracted tree.
            tar.extract(member, path=destination, filter="data")


def required_structure(name, root, version=None):
    root = Path(root)
    if name not in NAMES or not root.is_dir():
        raise ValueError(f"Missing/unsupported database directory: {name}: {root}")
    if name == "gtdbtk":
        directories = ["markers", "masks", "msa", "pplacer", "taxonomy", "radii", "metadata", "skani", "mrca_red", "split"]
        files = ["metadata/metadata.txt", "taxonomy/gtdb_taxonomy.tsv", "radii/gtdb_radii.tsv", "markers/tigrfam/tigrfam.hmm"]
    elif name == "checkm":
        directories = ["hmms", "pfam", "img", "genome_tree", "distributions"]
        files = ["hmms/phylo.hmm", "hmms/checkm.hmm", "pfam/Pfam-A.hmm.dat", "img/img_metadata.tsv", "selected_marker_sets.tsv", "taxon_marker_sets.tsv"]
    else:
        directories, files = [], ["uniref100.KO.1.dmnd"]
    for relative in directories:
        directory = root / relative
        if not directory.is_dir() or not any(directory.iterdir()):
            raise ValueError(f"Database {name} is missing a nonempty directory: {directory}")
    for relative in files:
        file = root / relative
        if not file.is_file() or file.stat().st_size == 0:
            raise ValueError(f"Database {name} is missing a nonempty file: {file}")
    if name == "gtdbtk" and version:
        metadata = (root / "metadata/metadata.txt").read_text()
        match = re.search(r"^VERSION_DATA\s*=\s*([^\s]+)", metadata, re.MULTILINE)
        if not match or match[1].strip("\"'").lower() != str(version).lower():
            raise ValueError(f"GTDB metadata does not match requested release {version}")
    return {"directories": directories, "files": files}


def locate_root(name, extracted, version=None):
    """Handle flat archives and one/two enclosing release directories."""
    extracted = Path(extracted)
    candidates = [extracted]
    candidates += [path for path in extracted.iterdir() if path.is_dir() and not path.is_symlink()]
    for parent in list(candidates[1:]):
        candidates += [path for path in parent.iterdir() if path.is_dir() and not path.is_symlink()]
    valid = []
    for path in candidates:
        try:
            required_structure(name, path, version)
        except ValueError:
            continue
        valid.append(path)
    if len(valid) != 1:
        raise ValueError(f"Expected one {name} database root in archive; found {len(valid)}")
    return valid[0]


def write_json(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=path.name + ".", delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(content, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def prepare(name, spec, marker):
    if name not in NAMES:
        raise ValueError(f"Unknown database: {name}")
    mode = spec.get("mode", "download")
    if mode not in {"download", "existing"}:
        raise ValueError("Database mode must be download or existing")
    if not isinstance(spec.get("path"), str) or not spec["path"].strip():
        raise ValueError("Database path must be a nonempty string")
    # A failed revalidation must not leave a stale success marker behind.
    Path(marker).unlink(missing_ok=True)
    target = Path(spec["path"]).expanduser().resolve()
    version = str(spec.get("version", ""))
    fingerprint = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()
    record = {"name": name, "mode": mode, "path": str(target), "version": version,
              "config_fingerprint": fingerprint,
              "prepared_at": datetime.now(timezone.utc).isoformat()}
    if mode == "existing":
        record["structure"] = required_structure(name, target, version)
    else:
        url = spec.get("url", "")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise ValueError("Database downloads require an HTTPS URL")
        manifest = target / MANIFEST
        if target.exists():
            if not manifest.is_file():
                raise ValueError(f"Refusing to overwrite existing database {target}; use mode: existing after validation")
            old = json.loads(manifest.read_text())
            if old.get("config_fingerprint") != fingerprint:
                raise ValueError(f"Database configuration changed for {target}; choose a new versioned path")
            record["structure"] = required_structure(name, target, version)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            archive = target.parent / ".downloads" / f"{name}-{version}.tar.gz"
            print(f"Downloading {name} {version} from {url}", flush=True)
            download(url, archive)
            with tempfile.TemporaryDirectory(prefix=f".{name}-extract-", dir=target.parent) as temporary:
                safe_extract(archive, temporary)
                source = locate_root(name, temporary, version)
                record["structure"] = required_structure(name, source, version)
                record["url"] = url
                write_json(source / MANIFEST, record)
                source.rename(target)
            # Check again after relocation; relative symlinks must remain valid.
            required_structure(name, target, version)
        record["url"] = url
    write_json(marker, record)
    print(f"Ready: {name}: {target}", flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", choices=sorted(NAMES), required=True)
    parser.add_argument("--spec", required=True, help="JSON database configuration")
    parser.add_argument("--marker", required=True)
    args = parser.parse_args()
    try:
        prepare(args.name, json.loads(args.spec), args.marker)
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as error:
        print(f"Database preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
