"""Validate workflow configuration and paired-read sample metadata."""
import csv
import os
import re
from pathlib import Path

STEPS = (
    "environment_ready", "prepare_database", "read_qc", "assembly", "index", "mapping", "sort_bam", "comebin", "semibin2",
    "metacat", "refinement", "refinem_stats", "refinem_outliers", "refinem_filter",
    "prepare_mags", "gtdbtk", "genes", "coverm_contig",
    "coverm_genome", "checkm", "checkm2",
)


def positive_int(value, name, allow_zero=False):
    if isinstance(value, bool) or not isinstance(value, int) or value < (0 if allow_zero else 1):
        raise ValueError(f"{name} must be an integer >= {0 if allow_zero else 1}")
    return value


def megahit_memory(value):
    return value if value < 1 else int(value * 1024 ** 3)


def megahit_preset_option(preset):
    return "--presets " + preset if preset else ""


def load_samples(filename):
    path = Path(os.path.expandvars(os.path.expanduser(filename))).resolve()
    samples = {}
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if not reader.fieldnames or not {"sample", "r1", "r2"}.issubset(reader.fieldnames):
            raise ValueError(f"{path}: requires tab-separated sample, r1, r2 columns")
        for line, row in enumerate(reader, start=2):
            sample = (row.get("sample") or "").strip()
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", sample):
                raise ValueError(f"{path}:{line}: invalid sample ID {sample!r}")
            if sample in samples:
                raise ValueError(f"{path}:{line}: duplicate sample ID {sample!r}")
            reads = {}
            for mate in ("r1", "r2"):
                value = (row.get(mate) or "").strip()
                if not value:
                    raise ValueError(f"{path}:{line}: {mate} is empty")
                read = Path(os.path.expandvars(os.path.expanduser(value)))
                reads[mate] = str((path.parent / read).resolve())
            if reads["r1"] == reads["r2"]:
                raise ValueError(f"{path}:{line}: r1 and r2 must be different files")
            samples[sample] = reads
    if not samples:
        raise ValueError(f"{path}: no samples")
    return samples


def validate_config(config):
    root = str(config.get("results_dir", "")).rstrip("/")
    # Directory outputs are removed by Snakemake when rerun. Keep results separate
    # from both the workflow sources and any input/read directories.
    if not root or root in (".", "..", "/") or "{" in root or "}" in root:
        raise ValueError("results_dir must be a dedicated output directory without wildcards")
    resolved = Path(root).resolve()
    if resolved == Path.cwd() or resolved in Path.cwd().parents:
        raise ValueError("results_dir cannot be the working directory or its ancestor")
    for step in STEPS:
        entry = config["resources"][step]
        unknown = set(entry) - {"threads", "partition", "runtime", "gpus"}
        if unknown:
            raise ValueError(f"resources.{step}: unsupported fields {sorted(unknown)}; use threads/partition/runtime/gpus")
        positive_int(entry["threads"], f"resources.{step}.threads")
        positive_int(entry["runtime"], f"resources.{step}.runtime")
        positive_int(entry.get("gpus", 0), f"resources.{step}.gpus", allow_zero=True)
        partition = config["partitions"].get(entry["partition"], entry["partition"])
        if not isinstance(partition, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*", partition):
            raise ValueError(f"resources.{step}.partition is invalid: {partition!r}")
    for step in ("gtdbtk", "genes", "checkm", "checkm2"):
        if not isinstance(config["analysis"][step], bool):
            raise ValueError(f"analysis.{step} must be true or false")
    assembly = config["assembly"]
    if assembly.get("tool", "spades") not in ("spades", "megahit"):
        raise ValueError("assembly.tool must be spades or megahit")
    positive_int(assembly["memory_gb"], "assembly.memory_gb")
    positive_int(assembly.get("min_contig_len", 1000), "assembly.min_contig_len")
    preset = assembly.get("megahit_preset", "")
    if preset not in ("", "meta-sensitive", "meta-large"):
        raise ValueError("assembly.megahit_preset must be empty, meta-sensitive or meta-large")
    memory = assembly.get("megahit_memory_gb", 0.9)
    if isinstance(memory, bool) or not isinstance(memory, (int, float)) or memory <= 0:
        raise ValueError("assembly.megahit_memory_gb must be a positive number")
    positive_int(config["gtdbtk"]["pplacer_threads"], "gtdbtk.pplacer_threads")
    positive_int(config["qc"]["length_required"], "qc.length_required")
    positive_int(config["qc"]["qualified_quality_phred"], "qc.qualified_quality_phred")
    for key in ("completeness", "contamination"):
        value = config["refinement"][key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
            raise ValueError(f"refinement.{key} must be between 0 and 100")
        if not isinstance(value, int):
            raise ValueError(f"Binette requires integer refinement.{key}")
    for key in ("min_length", "max_length"):
        positive_int(config["refinement"][key], "refinement." + key)
    if config["refinement"]["max_length"] < config["refinement"]["min_length"]:
        raise ValueError("refinement.max_length must be >= min_length")
    if not isinstance(config["refinem"]["enabled"], bool):
        raise ValueError("refinem.enabled must be true or false")
    for key in ("gc_percentile", "td_percentile"):
        value = positive_int(config["refinem"][key], "refinem." + key)
        if value > 100:
            raise ValueError(f"refinem.{key} must be <=100")
    positive_int(config["refinem"]["coverage_percent_error"], "refinem.coverage_percent_error")
    for key in ("min_alignment_fraction", "max_edit_distance_fraction"):
        value = config["refinem"][key]
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 1:
            raise ValueError(f"refinem.{key} must be between 0 and 1")
    if config["refinem"]["report_type"] not in ("any", "all"):
        raise ValueError("refinem.report_type must be any or all")
    return root
