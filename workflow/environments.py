"""Resolve managed specifications or existing Conda environments consistently."""
import os
import re
from pathlib import Path

from configuration import BINNER_TOOLS


TOOL_EXECUTABLES = {
    "fastp": ("fastp",),
    "spades": ("metaspades.py",),
    "megahit": ("megahit",),
    "minibwa": ("minibwa", "samtools"),
    "comebin": ("run_comebin.sh",),
    "semibin2": ("SemiBin2",),
    "metacat": ("MetaCAT",),
    "metabat2": ("metabat2", "jgi_summarize_bam_contig_depths"),
    "maxbin2": ("run_MaxBin.pl",),
    "binette": ("binette", "checkm2"),
    "refinem": ("refinem",),
    "gtdbtk": ("gtdbtk",),
    "pyrodigal": ("pyrodigal",),
    "bakta": ("bakta", "bakta_db"),
    "coverm": ("coverm",),
    "checkm": ("checkm",),
    "checkm2": ("checkm2",),
    "drep": ("dRep",),
}

ASSEMBLY_TOOLS = ("spades", "megahit")


def active_tool_executables(assembly_tool, binners=None, disabled=()):
    """Executables each environment must provide for the selected branches."""
    if assembly_tool not in ASSEMBLY_TOOLS:
        raise ValueError(f"assembly.tool must be one of {ASSEMBLY_TOOLS}; got {assembly_tool!r}")
    selected = set(BINNER_TOOLS) if binners is None else set(binners)
    if "maxbin2" in selected:
        selected.add("metabat2")
    inactive = set(disabled) | (set(ASSEMBLY_TOOLS) - {assembly_tool}) | (set(BINNER_TOOLS) - selected)
    return {tool: executables for tool, executables in TOOL_EXECUTABLES.items() if tool not in inactive}


def configure_conda(software, environ=None):
    """Allow GPU environment resolution on login nodes; never alter drivers."""
    environ = os.environ if environ is None else environ
    version = software.get("conda_cuda_override", "")
    if not isinstance(version, str) or (version and not re.fullmatch(r"\d+\.\d+", version)):
        raise ValueError("software.conda_cuda_override must be a CUDA major.minor string or empty")
    if version:
        environ.setdefault("CONDA_OVERRIDE_CUDA", version)


def resolve_environments(specifications, workflow_root, active_tools):
    """YAML -> deploy; name/prefix -> activate only, with no install hooks."""
    if not isinstance(specifications, dict):
        raise ValueError("environments must map each tool to an environment YAML, name or path")
    missing = set(active_tools) - set(specifications)
    unknown = set(specifications) - set(TOOL_EXECUTABLES)
    if missing or unknown:
        raise ValueError(f"Invalid environments keys: missing={sorted(missing)}, unknown={sorted(unknown)}")
    root = Path(workflow_root).resolve()
    resolved = {}
    for tool, specification in specifications.items():
        if not isinstance(specification, str) or not specification.strip():
            raise ValueError(f"environments.{tool} must be a nonempty YAML filename, name or path")
        value = os.path.expandvars(os.path.expanduser(specification.strip()))
        if any(character in value for character in ("\n", "\r", "{", "}")):
            raise ValueError(f"environments.{tool} contains invalid characters")
        if value.endswith((".yaml", ".yml")):
            path = (root / value).resolve()
            if not path.is_file():
                raise ValueError(f"Environment specification for {tool} does not exist: {path}")
            resolved[tool] = str(path)
        elif "/" in value:
            resolved[tool] = str((root / value).resolve())
        else:
            # Snakemake activates existing names without creating them. Prefix
            # existence is checked by Conda, not assumed on the authoring host.
            resolved[tool] = value
    return resolved
