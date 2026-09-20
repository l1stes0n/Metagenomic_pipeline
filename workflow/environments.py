"""Resolve managed specifications or existing Conda environments consistently."""
import os
import re
from pathlib import Path


TOOL_EXECUTABLES = {
    "fastp": ("fastp",),
    "spades": ("metaspades.py",),
    "minibwa": ("minibwa", "samtools"),
    "comebin": ("run_comebin.sh",),
    "semibin2": ("SemiBin2",),
    "metacat": ("MetaCAT",),
    "binette": ("binette", "checkm2"),
    "refinem": ("refinem",),
    "gtdbtk": ("gtdbtk",),
    "pyrodigal": ("pyrodigal",),
    "coverm": ("coverm",),
    "checkm": ("checkm",),
    "checkm2": ("checkm2",),
}


def configure_conda(software, environ=None):
    """Allow GPU environment resolution on login nodes; never alter drivers."""
    environ = os.environ if environ is None else environ
    version = software.get("conda_cuda_override", "")
    if not isinstance(version, str) or (version and not re.fullmatch(r"\d+\.\d+", version)):
        raise ValueError("software.conda_cuda_override must be a CUDA major.minor string or empty")
    if version:
        environ.setdefault("CONDA_OVERRIDE_CUDA", version)


def resolve_environments(specifications, workflow_root):
    """YAML -> deploy; name/prefix -> activate only, with no install hooks."""
    if not isinstance(specifications, dict):
        raise ValueError("environments must map each tool to an environment YAML, name or path")
    missing = set(TOOL_EXECUTABLES) - set(specifications)
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
