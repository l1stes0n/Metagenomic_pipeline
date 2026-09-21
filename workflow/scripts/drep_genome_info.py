#!/usr/bin/env python3
"""Convert a CheckM2 report into a dRep genomeInfo CSV."""
import argparse
import csv
from pathlib import Path

COMPLETENESS_COLUMNS = ("Completeness", "Completeness_General", "Completeness_Specific")
CONTAMINATION_COLUMNS = ("Contamination", "Contamination_General", "Contamination_Specific")


def pick_column(fieldnames, candidates, label):
    for name in candidates:
        if name in fieldnames:
            return name
    raise ValueError(f"CheckM2 report has no {label} column")


def read_quality(report):
    with Path(report).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        fields = reader.fieldnames or []
        completeness = pick_column(fields, COMPLETENESS_COLUMNS, "completeness")
        contamination = pick_column(fields, CONTAMINATION_COLUMNS, "contamination")
        quality = {}
        for row in reader:
            name = (row.get("Name") or "").strip()
            if not name:
                raise ValueError("CheckM2 report row without a Name")
            if name in quality:
                raise ValueError(f"Duplicate genome in CheckM2 report: {name}")
            quality[name] = (float(row[completeness]), float(row[contamination]))
    return quality


def collect_genomes(directories):
    genomes = {}
    for directory in directories:
        for path in sorted(Path(directory).glob("*.fna")):
            stem = path.with_suffix("").name
            if stem in genomes:
                raise ValueError(f"Duplicate genome basename: {stem}")
            genomes[stem] = path.name
    if not genomes:
        raise ValueError("No .fna genomes found")
    return genomes


def build_genome_info(report, directories, output):
    quality = read_quality(report)
    genomes = collect_genomes(directories)
    rows = []
    for stem, filename in sorted(genomes.items()):
        if stem not in quality:
            raise ValueError(f"No CheckM2 quality for genome: {stem}")
        completeness, contamination = quality[stem]
        rows.append([filename, completeness, contamination])
    with Path(output).open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["genome", "completeness", "contamination"])
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True)
    parser.add_argument("--genomes", nargs="+", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    build_genome_info(args.report, args.genomes, args.output)


if __name__ == "__main__":
    main()
