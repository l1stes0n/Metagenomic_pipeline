#!/usr/bin/env python3
"""Normalize FASTA extensions/headers without changing contig IDs."""
import argparse
import csv
import gzip
from pathlib import Path


def normalize_bins(source, destination, extension, skip_empty=False, report=None):
    source, destination = Path(source), Path(destination)
    files = sorted(p for p in source.iterdir() if p.is_file() and
                   any(p.name.endswith(s) for s in (".fa", ".fna", ".fasta", ".fa.gz", ".fna.gz", ".fasta.gz")))
    if not files:
        raise ValueError(f"No bin FASTA files in {source}")
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError(f"Refusing to mix bins with existing files in {destination}")
    names = set()
    records = []
    for source_file in files:
        name = source_file.name.removesuffix(".gz").rsplit(".", 1)[0]
        if name in names:
            raise ValueError(f"Duplicate bin basename: {name}")
        names.add(name)
        opener = gzip.open if source_file.suffix == ".gz" else open
        count, bases = 0, 0
        seen_contigs = set()
        with opener(source_file, "rt") as src, (destination / f"{name}.{extension}").open("w") as dst:
            for line in src:
                if line.startswith(">"):
                    fields = line[1:].split()
                    if not fields or fields[0] in seen_contigs:
                        raise ValueError(f"Empty or duplicate contig ID in {source_file}: {line.strip()}")
                    seen_contigs.add(fields[0])
                    count += 1
                    dst.write(">" + fields[0] + "\n")
                elif line.strip():
                    if count == 0:
                        raise ValueError(f"Sequence before FASTA header in {source_file}")
                    bases += len(line.strip())
                    dst.write(line.strip() + "\n")
        if (not count or not bases) and skip_empty:
            (destination / f"{name}.{extension}").unlink()
            records.append((name, "empty_after_filtering", count, bases))
            continue
        if not count or not bases:
            raise ValueError(f"Empty FASTA bin: {source_file}")
        records.append((name, "retained", count, bases))
    if report:
        with Path(report).open("w", newline="") as handle:
            writer = csv.writer(handle, delimiter="\t")
            writer.writerow(["bin", "status", "contigs", "bases"])
            writer.writerows(records)
    if not any(row[1] == "retained" for row in records):
        raise ValueError(f"No nonempty bins remain in {source}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bins = commands.add_parser("normalize")
    bins.add_argument("source")
    bins.add_argument("destination")
    bins.add_argument("--extension", choices=("fa", "fna"), required=True)
    bins.add_argument("--skip-empty", action="store_true", help="Record and omit bins emptied by RefineM")
    bins.add_argument("--report", help="Write a bin retention TSV")
    args = parser.parse_args()
    normalize_bins(args.source, args.destination, args.extension, args.skip_empty, args.report)


if __name__ == "__main__":
    main()
