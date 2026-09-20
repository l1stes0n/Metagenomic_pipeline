# Metagenomic Snakemake Workflow

**English** | [简体中文](README.zh-CN.md)

A Snakemake workflow for paired-end metagenomic data, providing per-sample assembly, parallel binning, MAG refinement, taxonomy, gene prediction, quality assessment, and abundance estimation. It supports multiple samples, resumable execution, and automated software and database deployment.

The workflow integrates fastp, metaSPAdes, minibwa, samtools, COMEBin, SemiBin2, MetaCAT, Binette, RefineM, GTDB-Tk, Pyrodigal, CheckM, CheckM2, and CoverM.

## Workflow Overview

```text
    Paired-end FASTQ
            │
            ▼
       fastp (QC)
            │
            ▼
     filtered reads
            │
            ├───────────────────────────────────────┐
            │                                       │
            ▼                                       │
  metaSPAdes (assembly)                             │
            │                                       │
            ▼                                       │
     scaffolds.fasta                                │
            │                                       │
            ▼                                       │
      minibwa index                                 │
            │                                       │
            └────────────► minibwa map ◄────────────┘
                                │
                                ▼
                      samtools sort / index
                          assembly.bam
                                │
        ┌───────────────┬───────┴───────┬───────────────┬─────────┐
        │               │               │               │         │
     COMEBin        SemiBin2         MetaCAT      CoverM contig   │
        │               │               │          (from BAM)     │
        └───────────────┴───────┬───────┘                         │
                                ▼                                 │
                 Binette + CheckM2 (refinement)                   │
                                │                                 │
                                ▼                                 │
                     RefineM scaffold_stats ◄─────────────────────┘
                                │
                                ▼
                        RefineM outliers
                                │
                                ▼
                       RefineM filter_bins
                                │
                                ▼
                        Final MAGs (.fna)
                                │
      ┌────────────┬────────────┼────────────┬───────────────┐
      │            │            │            │               │
   GTDB-Tk     Pyrodigal     CheckM       CheckM2      CoverM genome
  taxonomy       genes         QC           QC          (abundance)
      │            │            │            │               │
      └────────────┴────────────┼────────────┴───────────────┘
                                ▼
                        results/ + logs/

Reference databases (prepared once, shared by all samples)
  ├── GTDB-Tk R232 ────────► GTDB-Tk taxonomy
  ├── CheckM 2015_01_16 ───► COMEBin and CheckM
  └── CheckM2 v3 ──────────► Binette and CheckM2
```

## Installation and Initial Configuration

Run the workflow from a submission node with access to Slurm. The workflow directory, reads, databases, and Conda environments must reside on a shared filesystem visible from compute nodes.

The following Slurm commands must be available:

- `sbatch`
- `squeue`
- `sacct`
- `scancel`

The `sacct` command must be able to query completed jobs.

Avoid spaces in project, environment, and database paths. Although the workflow quotes paths, some third-party tools, including Binette, do not fully support paths containing spaces.

```bash
cd /path/to/snakemake
conda env create -f environment.yaml
conda activate metagenomic-workflow
```

The control environment uses Snakemake 9 and the Slurm executor plugin. Tool-specific environments are defined by the YAML files below and created automatically; Conda deployment is enabled by the supplied Slurm profile.

| Environment | Configuration file |
| --- | --- |
| fastp | `workflow/envs/fastp.yaml` |
| spades | `workflow/envs/spades.yaml` |
| minibwa | `workflow/envs/minibwa.yaml` |
| comebin | `workflow/envs/comebin.yaml` |
| semibin2 | `workflow/envs/semibin2.yaml` |
| metacat | `workflow/envs/metacat.yaml` |
| binette | `workflow/envs/binette.yaml` |
| refinem | `workflow/envs/refinem.yaml` |
| gtdbtk | `workflow/envs/gtdbtk.yaml` |
| pyrodigal | `workflow/envs/pyrodigal.yaml` |
| checkm | `workflow/envs/checkm.yaml` |
| checkm2 | `workflow/envs/checkm2.yaml` |
| coverm | `workflow/envs/coverm.yaml` |

To pre-install all tool environments:

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda
```

This target creates the environments and verifies that the required commands are available.

To create environments without running command-availability checks:

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --conda-create-envs-only
```

This step is optional: a full run creates all environments required by its DAG.

The default environment cache is `.snakemake/conda/`. To place it on shared storage, use a common prefix for both installation and production runs:

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --conda-prefix /shared/conda/snakemake-envs
```

Internet access is required during initial environment installation.

### Using Existing Environments

Replace entries under `environments` in `config/config.yaml`, or use `config/environments.local.yaml` as a local override:

```yaml
environments:
  minibwa: my-minibwa
  comebin: /shared/conda/envs/comebin
  metacat: /shared/conda/envs/metacat
  coverm: workflow/envs/coverm.yaml
```

Run with the override file:

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --configfile config/environments.local.yaml

snakemake \
  --workflow-profile slurm \
  --configfile config/environments.local.yaml
```

A YAML path defines an environment managed by Snakemake. A plain environment name or directory activates an existing environment without reinstalling it or running post-deploy hooks. Existing environments must be available on compute nodes and provide all required commands and dependencies, including samtools for minibwa and CuPy for MetaCAT. Relative YAML paths are resolved from the workflow directory; environment-directory values support absolute paths, `~`, and environment variables.

See the [Snakemake documentation on integrated package management and post-deployment scripts](https://snakemake.readthedocs.io/en/stable/snakefiles/deployment.html).

### GPU Installation and Runtime Requirements

The default GPU software stack targets Linux x86_64. The configured runtime baseline on GPU nodes is:

- **glibc 2.28 or newer**
- **NVIDIA driver 560.35.05 or newer**

COMEBin uses CUDA 12.6 PyTorch, and MetaCAT uses CUDA 12.6 CuPy. The CUDA 12.0 build used by SemiBin2 can run with the same driver baseline.

The driver requirement follows the [NVIDIA CUDA 12.6 Update 3 release notes](https://docs.nvidia.com/cuda/archive/12.6.3/cuda-toolkit-release-notes/index.html). Different cluster configurations can be supported by supplying existing environments or custom YAML definitions.

The following configuration allows Conda to resolve GPU environments on a submission node without a GPU:

```yaml
software:
  conda_cuda_override: "12.6"
```

This setting affects Conda dependency resolution only. It does not install drivers or configure Slurm. An external `CONDA_OVERRIDE_CUDA` takes precedence; an empty value enables automatic detection.

Each GPU binning job validates CUDA after allocation and fails instead of silently falling back to the CPU.

### Required Configuration Files

Edit the following files before running the workflow:

- `config/samples.tsv`: one sample per row, with tab-separated columns `sample`, `r1`, and `r2`. FASTQ and gzip-compressed FASTQ files are supported. Relative paths are resolved against the directory containing the TSV file; absolute paths are recommended. Sample IDs must be unique, start with a letter or number, and contain only letters, numbers, periods, underscores, and hyphens.
- `config/config.yaml`: review partitions, analysis parameters, and any existing software-environment overrides.
- `config/databases.yaml`: select automatic database downloads or existing databases and configure shared-storage paths.

Example `config/samples.tsv`:

```tsv
sample	r1	r2
sampleA	/data/sampleA_R1.fastq.gz	/data/sampleA_R2.fastq.gz
sampleB	/data/sampleB_R1.fastq.gz	/data/sampleB_R2.fastq.gz
```

> [!NOTE]
> Verify available partitions with `sinfo -o '%P %c %l'`. Partition names do not determine the CPU or memory resources requested by a rule.

## Database Management

The `prepare_database` rule performs resumable downloads, safe extraction, directory-structure validation, and atomic publication. Each of the three databases is prepared once on shared storage and reused by all samples.

| Database | Pinned release | Used by |
| --- | --- | --- |
| GTDB-Tk | R232 | GTDB-Tk 2.7.2 taxonomy assignment |
| CheckM | 2015_01_16 | COMEBin final filtering and independent CheckM1 quality assessment |
| CheckM2 | Zenodo 14897628, Version 3 | Binette refinement and independent CheckM2 quality assessment |

Download URLs and versions are centralized in `config/databases.yaml`.

- GTDB-Tk compatibility follows the [official database installation documentation](https://ecogenomics.github.io/GTDBTk/installing/index.html).
- CheckM uses the pinned [CheckM archive](https://zenodo.org/records/7401545).
- CheckM2 uses the pinned [CheckM2 archive](https://zenodo.org/records/14897628).

On the first run, prepare the databases on a node with internet access and write access to shared storage:

```bash
snakemake prepare_databases --cores 4
```

Databases can also be prepared through an internet-enabled compute partition:

```bash
snakemake prepare_databases \
  --workflow-profile slurm \
  --jobs 3
```

Database preparation is included in the full DAG. The explicit `prepare_databases` target prepares all three databases; a normal run prepares only those required by enabled branches.

GTDB is large. Reserve enough space for the compressed archive, the temporary extraction directory, and the final database. Download archives are retained under `.downloads/` in each database's parent directory to support resumption and reuse.

### Reusing Existing Databases

Existing read-only databases can be configured as follows:

```yaml
databases:
  gtdbtk:
    mode: existing
    path: /shared/db/gtdbtk/r232
    version: r232
  checkm:
    mode: existing
    path: /shared/db/checkm/2015_01_16
    version: "2015_01_16"
  checkm2:
    mode: existing
    path: /shared/db/checkm2/CheckM2_database
    version: "3"
```

Each `path` must point to the actual database root:

- The CheckM2 root must directly contain `uniref100.KO.1.dmnd`.
- The GTDB-Tk root must directly contain `metadata/`, `markers/`, and the other required directories. Do not point to their parent directory.

Existing-database mode validates the required paths and files. GTDB releases other than R232 require a compatible GTDB-Tk environment. Use a new version-specific directory when changing database releases.

Readiness records are stored under:

```text
results/00_databases/*.ready.json
```

If a database is manually moved, deleted, or damaged, rerun the preparation rule and force validation:

```bash
snakemake prepare_databases \
  --cores 4 \
  --forcerun prepare_database
```

Do not retain a readiness record after removing its database. RefineM filters bins by genome properties, independent of any taxonomic reference database.

COMEBin additionally requires the CheckM1 database for final candidate filtering.

## Slurm CPU and Partition Handling

**Snakemake `threads` is the single source of truth for CPU requests.**

The profile uses the official [Slurm executor plugin](https://snakemake.github.io/snakemake-plugin-catalog/plugins/executor/slurm.html), which maps rule resources to `sbatch` arguments: `threads` to `--cpus-per-task`, `resources.slurm_partition` to `--partition`, `resources.gpu` to `--gpus`, `runtime` (minutes) to `--time`, and `slurm_account` to `--account`. Change `resources.<rule>.threads` or use `--set-threads` to override CPU allocation. Application-level concurrency arguments are derived from the same thread count and do not read `SLURM_CPUS_PER_TASK`.

Because `mem_mb` and `disk_mb` default to `0`, no `--mem` request is sent. The `constraint` resource is never set, so no `--constraint` or Slurm feature request is passed. Each compute job uses one node and one task.

If `slurm_account` is empty, the executor plugin infers the account from Slurm accounting; set `slurm_account` in `config/config.yaml` to pin a specific account.

The plugin does not sanitize inherited `SBATCH_*` or `SLURM_*` variables; start Snakemake from a clean environment if your site presets such variables.

`assembly.memory_gb` is used only as the **metaSPAdes application memory limit** through `metaspades.py -m`. It is not a Slurm memory request. The default value of 1500 GB is inherited from the original script. Adjust it to the actual memory of nodes in the assembly partition and set an appropriate job concurrency limit.

minibwa may create two additional I/O threads. The mapping worker count is therefore calculated as `max(1, threads - 2)`. BAM sorting and indexing run separately, and `samtools -@` receives `threads - 1`.

Intermediate SAM files are marked with `temp()` and removed after sorting, but sufficient temporary disk space is required while mapping is running. Steps that use process pools restrict BLAS and OpenMP library threads to prevent nested concurrency from multiplying the requested CPU count.

See the [minibwa threading documentation](https://github.com/lh3/minibwa/blob/master/minibwa.1).

## Execution, Resumption, and Logs

Run all commands from the workflow directory. After configuring real FASTQ paths, start the analysis:

```bash
snakemake \
  --workflow-profile slurm \
  --jobs 20
```

`--jobs` limits concurrent jobs, while each rule's `threads` value controls its CPU request. Run Snakemake in `tmux` for long analyses. Rerun the same command to resume; the profile enables `rerun-incomplete`.

Example resource overrides:

```bash
snakemake \
  --workflow-profile slurm \
  --jobs 10 \
  --set-threads \
    assembly=48 \
    mapping=24 \
    refinement=24 \
    refinem_stats=12 \
    gtdbtk=24 \
  --set-resources \
    assembly:partition=x86_64_8cpu \
    assembly:runtime=5760
```

Log locations:

- External program logs: `logs/<rule>/<sample>.log`
- Slurm job logs: `logs/slurm/`
- Database preparation logs: `results/logs/databases/`

Job status is queried from Slurm accounting (`sacct`). Terminal failure states such as `FAILED`, `TIMEOUT`, and `OUT_OF_MEMORY` are reported as job failures; nodes that fail during a run are recorded, excluded from later submissions, and reported at the end.

Slurm job names are the workflow run UUID; the rule and wildcards of each job are stored in the Slurm comment (`rule_<rule>_wildcards_<wildcards>`). To inspect jobs with readable metadata:

```bash
squeue -u "$USER" -o "%.10i %.32j %.45k %.10T %.10M"
```

## Analysis Parameters and Outputs

### Quality Control

fastp enables paired-end adapter detection by default, requires a qualified-base threshold of Q20, and retains reads with a minimum length of 50 bases. Host removal is not performed.

Quality-control parameters are configured under `qc`. See the [fastp documentation](https://github.com/OpenGene/fastp).

### Assembly

Each sample is assembled independently with **metaSPAdes** in `--only-assembler` mode. The default k-mer sizes are 21, 33, 55, 77, 99, and 127; `assembly.kmers` and `assembly.memory_gb` set the k-mer list and the metaSPAdes memory limit (`-m`). The assembly is written to `02_assembly/<sample>/scaffolds.fasta`.

See the [SPAdes documentation](https://github.com/ablab/spades).

### Mapping

minibwa indexes the assembly, and the quality-controlled reads are mapped back to it; samtools then sorts and indexes the alignments. The mapping worker count is `max(1, threads - 2)`, and sorting and indexing use `threads - 1`. The output is `03_mapping/<sample>/assembly.bam` with its `.bai` index. The same BAM is reused by binning, RefineM, and CoverM.

See the [minibwa documentation](https://github.com/lh3/minibwa).

### Binning

Three binners run in parallel on every sample; each job validates GPU availability before starting:

- **COMEBin** applies contrastive multi-view representation learning to the assembly and BAM, and additionally requires the CheckM database.
- **SemiBin2** runs `single_easy_bin` with the global environment model.
- **MetaCAT** performs coverage calculation, seeding, and clustering in sequence.

Each tool's output is normalized to FASTA (`.fa`) with unchanged contig IDs under `04_binning/<sample>/{comebin,semibin2,metacat}/`.

See the [COMEBin](https://github.com/ziyewang/COMEBin), [SemiBin2](https://github.com/BigDataBiology/SemiBin), and [MetaCAT](https://github.com/liu-congcong/MetaCAT) repositories.

### Bin Refinement

Binette generates candidate bins through intersections, differences, and unions of multiple bin sets and scores them with CheckM2.

The `refinement` section controls completeness, contamination, contamination-score weighting, and bin-length limits.

See the [pinned Binette parameter implementation](https://github.com/genotoul-bioinfo/Binette/blob/v1.2.1/binette/main.py).

### RefineM Filtering

RefineM runs the following three-stage workflow by default:

```text
scaffold_stats -> outliers -> filter_bins
```

It uses the assembly FASTA, Binette bins, and the original assembly BAM. Default filtering criteria are:

- 98th percentile for GC-content and tetranucleotide distributions
- 50% mean absolute percentage error for coverage
- A contig is filtered when it is an outlier for any enabled criterion
- Correlation-based filtering is disabled for single-sample coverage with a threshold of `-2`

Configure these values under `refinem`, or set `enabled: false` to disable filtering. Empty bins are removed and recorded in `bin_retention.tsv`; the rule fails if no bins remain.

See the [official RefineM contamination-identification workflow](https://github.com/donovan-h-parks/RefineM#identifying-potential-contamination).

### Final Quality Assessment

CheckM and CheckM2 reassess the final MAGs **after RefineM filtering**. Binette's intermediate quality table describes pre-filtering bins only.

Because RefineM may reduce both contamination and completeness, use the post-filtering CheckM and CheckM2 reports for downstream decisions.

The `analysis` configuration can disable the following branches:

- GTDB-Tk taxonomy
- Gene prediction
- Independent CheckM assessment
- Independent CheckM2 assessment

Disabling the independent CheckM2 branch does not remove Binette's dependency on the CheckM2 database. Disabling the independent CheckM branch does not remove COMEBin's dependency on the CheckM1 database.

### Taxonomy

GTDB-Tk classifies the final MAGs against the pinned GTDB R232 release with `classify_wf --skip_ani_screen`. pplacer threads are capped by `gtdbtk.pplacer_threads`. Results are written to `07_taxonomy/<sample>/`.

See the [GTDB-Tk documentation](https://ecogenomics.github.io/GTDBTk/).

### Gene Prediction

Gene prediction uses **Pyrodigal 3.7.1**. Each final MAG is trained and predicted independently with `-p single`, while contigs are processed in parallel using `-j {threads} --pool thread`.

For each MAG, the workflow produces:

- Protein sequences: `.faa`
- Gene nucleotide sequences: `.ffn`
- Gene annotations: `.gff`

Pyrodigal is managed through `workflow/envs/pyrodigal.yaml` by default; `environments.pyrodigal` can select an existing environment.

See the [Pyrodigal 3.7.1 command-line documentation](https://pyrodigal.readthedocs.io/en/v3.7.1/guide/cli.html).

### Abundance

CoverM calculates abundance from the assembly BAM in two modes: `coverm contig`, and `coverm genome` against the final MAGs. Both report trimmed-mean coverage, length, count, RPKM, and TPM; genome mode additionally reports relative abundance and uses `--min-covered-fraction 0`. Outputs are `09_abundance/<sample>/contig.tsv` and `09_abundance/<sample>/genome.tsv`.

See the [CoverM documentation](https://github.com/wwood/CoverM).

### Output Directory Structure

| Path | Contents |
| --- | --- |
| `01_qc/<sample>/` | fastp-filtered reads and HTML/JSON reports |
| `02_assembly/<sample>/scaffolds.fasta` | metaSPAdes assembly |
| `03_mapping/<sample>/` | minibwa index and sorted BAM/BAI files |
| `04_binning/<sample>/<binner>/` | Raw outputs from the three binners and normalized `.fa` bins |
| `05_refinement/<sample>/` | Binette `final_bins/` and pre-filtering quality table |
| `05_refinem/<sample>/` | Scaffold statistics, outlier tables, filtered bins, and retention records |
| `06_mags/<sample>/*.fna` | Final MAGs used by all downstream branches |
| `07_taxonomy/<sample>/` | GTDB-Tk taxonomy results |
| `08_genes/<sample>/` | Per-MAG protein `.faa`, gene `.ffn`, and `.gff` files |
| `09_abundance/<sample>/{contig,genome}.tsv` | CoverM abundance tables |
| `10_checkm/<sample>/quality_report.tsv` | CheckM assessment of final MAGs |
| `11_checkm2/<sample>/` | CheckM2 quality table and dRep-compatible CSV for final MAGs |

Each sample is assembled, binned, and quantified independently. CoverM uses the same assembly BAM as the binning stage. FASTA normalization preserves contig identifiers so that they remain consistent with BAM references.

COMEBin receives a separate FASTA copy to prevent marker files from modifying the shared assembly directory. If any binner produces no bins, the corresponding rule fails instead of allowing an empty directory to continue downstream.

Snakemake manages some complete tool-output directories with `directory()`. These directories are recreated during reruns. Do not place raw reads or the only copy of important data inside them.

Manual changes to individual files inside a managed directory may not update its directory timestamp. Use `--forcerun` for the relevant rule when such changes must be recognized.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.
