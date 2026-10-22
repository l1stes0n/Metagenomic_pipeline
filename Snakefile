"""Per-sample metagenomic analysis; all scheduling is owned by Snakemake."""
import shlex
import sys
from pathlib import Path

from snakemake.utils import min_version

min_version("9.0")
configfile: "config/config.yaml"
configfile: "config/databases.yaml"

WORKFLOW_ROOT = Path(workflow.basedir).resolve()
sys.dont_write_bytecode = True
sys.path.insert(0, str(WORKFLOW_ROOT / "workflow"))
from configuration import load_samples, megahit_memory, megahit_preset_option, validate_config
from environments import active_tool_executables, configure_conda, resolve_environments

ROOT = validate_config(config)
configure_conda(config["software"])
SAMPLE_DATA = load_samples(config["samples"])
SAMPLES = list(SAMPLE_DATA)
ASSEMBLY_TOOL = config["assembly"].get("tool", "spades")
DREP_SAMPLE = config.get("drep", {}).get("sample", False)
DREP_CROSS = config.get("drep", {}).get("cross_sample", False)
DREP_ENABLED = DREP_SAMPLE or DREP_CROSS
QC_ENABLED = config["qc"]["enabled"]
REFINEMENT_ENABLED = config["refinement"]["enabled"]
REFINEM_ENABLED = config["refinem"]["enabled"] and REFINEMENT_ENABLED
ABUNDANCE_CONTIG = config["abundance"]["contig"]
ABUNDANCE_GENOME = config["abundance"]["genome"]
BINNERS = config["binning"]["tools"]
BAKTA_ENABLED = config["analysis"]["bakta"]
DISABLED = {
    tool
    for tool, enabled in (
        ("fastp", QC_ENABLED),
        ("binette", REFINEMENT_ENABLED),
        ("refinem", REFINEM_ENABLED),
        ("coverm", ABUNDANCE_CONTIG or ABUNDANCE_GENOME),
        ("gtdbtk", config["analysis"]["gtdbtk"]),
        ("pyrodigal", config["analysis"]["genes"]),
        ("checkm", config["analysis"]["checkm"]),
        ("checkm2", config["analysis"]["checkm2"] or DREP_ENABLED),
        ("bakta", BAKTA_ENABLED),
        ("drep", DREP_ENABLED),
    )
    if not enabled
}
ACTIVE_TOOLS = active_tool_executables(ASSEMBLY_TOOL, BINNERS, DISABLED)
ENVS = resolve_environments(config["environments"], WORKFLOW_ROOT, ACTIVE_TOOLS)
PYTHON = sys.executable
BIN_UTILS = str(WORKFLOW_ROOT / "workflow/scripts/bin_utils.py")

shell.executable("/bin/bash")
# Setting a custom prefix replaces Snakemake's default Bash strict mode.
shell.prefix("set -euo pipefail; source " + shlex.quote(str(WORKFLOW_ROOT / "workflow/scripts/common.sh")) + "; ")


def setting(step, key):
    if key == "partition":
        name = config["resources"][step][key]
        return config["partitions"].get(name, name)
    return config["resources"][step].get(key, 0 if key == "gpus" else None)


def threshold(key):
    # Binette accepts integer quality thresholds.
    return str(config["refinement"][key])


QC = ROOT + "/01_qc/{sample}"
ASSEMBLY = ROOT + "/02_assembly/{sample}"
INDEX = ROOT + "/03_mapping/{sample}/reference"
BAM = ROOT + "/03_mapping/{sample}/assembly.bam"
BINNING = ROOT + "/04_binning/{sample}"
REFINEMENT = ROOT + "/05_refinement/{sample}"
REFINEM = ROOT + "/05_refinem/{sample}"
MAGS = ROOT + "/06_mags/{sample}"
MAGS_SOURCE = ROOT + "/06_drep/{sample}/mags" if DREP_SAMPLE else MAGS

if REFINEM_ENABLED:
    MAGS_BINS = REFINEM + "/filtered"
    MAGS_BINS_SUBDIR = "bins"
elif REFINEMENT_ENABLED:
    MAGS_BINS = REFINEMENT
    MAGS_BINS_SUBDIR = "final_bins"
else:
    # Validation requires a single binner when refinement is disabled.
    MAGS_BINS = BINNING + "/" + BINNERS[0]
    MAGS_BINS_SUBDIR = BINNERS[0] + "_bins"

FINAL_TARGETS = expand(MAGS, sample=SAMPLES)
if ABUNDANCE_CONTIG:
    FINAL_TARGETS += expand(ROOT + "/09_abundance/{sample}/contig.tsv", sample=SAMPLES)
if ABUNDANCE_GENOME:
    FINAL_TARGETS += expand(ROOT + "/09_abundance/{sample}/genome.tsv", sample=SAMPLES)
for enabled, folder in (("gtdbtk", "07_taxonomy"), ("genes", "08_genes"), ("bakta", "13_bakta"),
                        ("checkm", "10_checkm"), ("checkm2", "11_checkm2")):
    if config["analysis"][enabled]:
        FINAL_TARGETS += expand(ROOT + "/" + folder + "/{sample}", sample=SAMPLES)
if DREP_CROSS:
    FINAL_TARGETS.append(ROOT + "/12_drep/mags")

wildcard_constraints:
    sample="(?:" + "|".join(__import__("re").escape(s) for s in SAMPLES) + ")"

rule all:
    input:
        FINAL_TARGETS
    default_target: True

include: "workflow/rules/preprocess.smk"
include: "workflow/rules/environments.smk"
include: "workflow/rules/databases.smk"
include: "workflow/rules/binning.smk"
include: "workflow/rules/refinem.smk"
include: "workflow/rules/drep.smk"
include: "workflow/rules/downstream.smk"
