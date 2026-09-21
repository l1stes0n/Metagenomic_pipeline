# 宏基因组 Snakemake 工作流

[English](README.md) | **简体中文**

一个面向双端宏基因组数据的 Snakemake 工作流，支持逐样本组装、并行分箱、MAG 精炼、分类注释、基因预测、质量评估和丰度计算，并提供多样本处理、断点续跑以及软件和数据库的自动部署。

本工作流主要使用 fastp、metaSPAdes、minibwa、samtools、COMEBin、SemiBin2、MetaCAT、Binette、RefineM、GTDB-Tk、Pyrodigal、CheckM、CheckM2 和 CoverM。

## 工作流概览

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

## 安装与初始配置

请从能够访问 Slurm 的提交节点运行工作流。工作流目录、测序数据、数据库和 Conda 环境必须位于计算节点可访问的共享文件系统中。

系统必须提供以下 Slurm 命令：

- `sbatch`
- `squeue`
- `sacct`
- `scancel`

其中，`sacct` 必须能够查询已结束的作业。

项目、环境和数据库路径中应避免使用空格。虽然工作流会正确引用路径，但包括 Binette 在内的部分第三方工具无法完整支持带空格的路径。

```bash
cd /path/to/snakemake
conda env create -f environment.yaml
conda activate metagenomic-workflow
```

控制环境使用 Snakemake 9 和 Slurm executor 插件。各工具环境由下表所列 YAML 定义并自动创建，使用随附的 Slurm profile 时会自动启用 Conda 部署。

| 环境 | 配置文件 |
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

预安装全部工具环境：

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda
```

该目标会创建环境并验证所需命令是否可用。

如果只创建环境而不检查命令：

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --conda-create-envs-only
```

该步骤可选：完整运行会自动创建实际 DAG 所需的环境。

默认环境缓存位于 `.snakemake/conda/`。如需将环境放在共享存储中，安装和正式运行时应使用相同的前缀：

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --conda-prefix /shared/conda/snakemake-envs
```

首次安装环境时需要联网。

### 使用已有环境

可以修改 `config/config.yaml` 中的 `environments`，也可以使用 `config/environments.local.yaml` 作为本地覆盖配置：

```yaml
environments:
  minibwa: my-minibwa
  comebin: /shared/conda/envs/comebin
  metacat: /shared/conda/envs/metacat
  coverm: workflow/envs/coverm.yaml
```

使用覆盖配置运行：

```bash
snakemake prepare_environments \
  --cores 1 \
  --software-deployment-method conda \
  --configfile config/environments.local.yaml

snakemake \
  --workflow-profile slurm \
  --configfile config/environments.local.yaml
```

YAML 路径表示由 Snakemake 创建和管理环境。普通环境名或环境目录表示直接激活已有环境，不会重新安装，也不会执行 post-deploy hook。已有环境必须能被计算节点访问，并提供全部必需命令和依赖，例如 minibwa 环境还需提供 samtools，MetaCAT 环境还需提供 CuPy。相对 YAML 路径以工作流目录为基准；环境目录支持绝对路径、`~` 和环境变量。

参见 [Snakemake 软件部署与 post-deployment 脚本文档](https://snakemake.readthedocs.io/en/stable/snakefiles/deployment.html)。

### GPU 安装与运行要求

默认 GPU 软件栈面向 Linux x86_64，GPU 节点的运行基线为：

- **glibc 2.28 或更高版本**
- **NVIDIA 驱动 560.35.05 或更高版本**

COMEBin 使用 CUDA 12.6 版 PyTorch，MetaCAT 使用 CUDA 12.6 版 CuPy。SemiBin2 使用的 CUDA 12.0 构建可在相同的驱动基线上运行。

驱动要求依据 [NVIDIA CUDA 12.6 Update 3 发布说明](https://docs.nvidia.com/cuda/archive/12.6.3/cuda-toolkit-release-notes/index.html)。如集群配置不同，可通过已有环境或自定义 YAML 覆盖默认配置。

以下配置允许 Conda 在没有 GPU 的提交节点上解析 GPU 环境：

```yaml
software:
  conda_cuda_override: "12.6"
```

该设置只影响 Conda 的依赖解析，不会安装驱动或配置 Slurm。外部定义的 `CONDA_OVERRIDE_CUDA` 优先级更高；配置为空时使用自动检测。

每个 GPU 分箱任务都会在获得 GPU 资源后验证 CUDA。如果验证失败，任务将直接终止，而不会静默回退到 CPU。

### 必需的配置文件

运行前请编辑以下文件：

- `config/samples.tsv`：每行一个样本，使用制表符分隔 `sample`、`r1` 和 `r2` 三列。支持 FASTQ 和 gzip 压缩的 FASTQ。相对路径以 TSV 所在目录为基准，建议使用绝对路径。样本 ID 必须唯一，以字母或数字开头，并且只能包含字母、数字、点、下划线和短横线。
- `config/config.yaml`：检查分区、分析参数和已有软件环境覆盖项。
- `config/databases.yaml`：选择自动下载或复用已有数据库，并设置共享存储路径。

`config/samples.tsv` 示例：

```tsv
sample	r1	r2
sampleA	/data/sampleA_R1.fastq.gz	/data/sampleA_R2.fastq.gz
sampleB	/data/sampleB_R1.fastq.gz	/data/sampleB_R2.fastq.gz
```

> [!NOTE]
> 使用 `sinfo -o '%P %c %l'` 检查可用分区。分区名称本身不决定规则申请的 CPU 数量或内存大小。

## 数据库管理

`prepare_database` 规则负责断点续传、安全解压、目录结构检查和原子发布。三个数据库分别只准备一次，并由所有样本共享。

| 数据库 | 固定版本 | 使用方 |
| --- | --- | --- |
| GTDB-Tk | R232 | GTDB-Tk 2.7.2 分类注释 |
| CheckM | 2015_01_16 | COMEBin 最终筛选和独立 CheckM1 质量评估 |
| CheckM2 | Zenodo 14897628，Version 3 | Binette 精炼和独立 CheckM2 质量评估 |

下载地址和版本集中保存在 `config/databases.yaml` 中。

- GTDB-Tk 的兼容性依据[官方数据库安装文档](https://ecogenomics.github.io/GTDBTk/installing/index.html)。
- CheckM 使用固定的 [CheckM 存档](https://zenodo.org/records/7401545)。
- CheckM2 使用固定的 [CheckM2 存档](https://zenodo.org/records/14897628)。

首次运行时，请在能够联网并写入共享存储的节点上准备数据库：

```bash
snakemake prepare_databases --cores 4
```

也可以通过能够联网的计算分区准备数据库：

```bash
snakemake prepare_databases \
  --workflow-profile slurm \
  --jobs 3
```

数据库准备已经包含在完整 DAG 中。显式执行 `prepare_databases` 会准备全部三个数据库；正常分析只准备已启用分支所需的数据库。

GTDB 数据量较大，请为压缩包、临时解压目录和最终数据库预留足够空间。下载文件会保留在各数据库父目录下的 `.downloads/` 中，以便断点续传和复用。

### 复用已有数据库

可以按以下方式配置只读的已有数据库：

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

每个 `path` 都必须指向实际数据库根目录：

- CheckM2 根目录必须直接包含 `uniref100.KO.1.dmnd`。
- GTDB-Tk 根目录必须直接包含 `metadata/`、`markers/` 和其他必需目录，不能指向其上一级目录。

已有数据库模式会检查必需路径和文件。R232 以外的 GTDB 版本需要使用兼容的 GTDB-Tk 环境。更换数据库版本时，应使用新的版本目录。

数据库就绪记录保存在：

```text
results/00_databases/*.ready.json
```

如果数据库被手动移动、删除或损坏，可强制重新检查并修复：

```bash
snakemake prepare_databases \
  --cores 4 \
  --forcerun prepare_database
```

删除数据库后，不应保留对应的就绪记录。RefineM 基于基因组属性过滤，不依赖分类参考数据库。

COMEBin 的最终候选筛选还需要 CheckM1 数据库。

## Slurm CPU 与分区管理

**Snakemake 的 `threads` 是 CPU 请求的唯一来源。**

Profile 使用官方 [Slurm executor 插件](https://snakemake.github.io/snakemake-plugin-catalog/plugins/executor/slurm.html)，将规则资源映射为 `sbatch` 参数：`threads` → `--cpus-per-task`，`resources.slurm_partition` → `--partition`，`resources.gpu` → `--gpus`，`runtime`（分钟）→ `--time`，`slurm_account` → `--account`。可以修改 `resources.<rule>.threads`，或使用 `--set-threads` 覆盖 CPU 数量。各程序的并发参数由同一线程数派生，不读取 `SLURM_CPUS_PER_TASK`。

由于 `mem_mb` 和 `disk_mb` 默认为 `0`，不会发送 `--mem` 请求；`constraint` 资源始终未设置，因此也不会传递 `--constraint` 或 Slurm feature 请求。每个计算作业使用一个节点和一个任务。

`slurm_account` 为空时，执行器插件会从 Slurm 记账信息中推断账号；如需固定账号，请在 `config/config.yaml` 中设置 `slurm_account`。

插件不会清理继承的 `SBATCH_*` 或 `SLURM_*` 变量；如果集群环境预设了这些变量，请在干净的环境中启动 Snakemake。

`assembly.memory_gb` 仅通过 `metaspades.py -m` 设置 **metaSPAdes 的程序内存上限**，不是 Slurm 内存请求。默认值 1500 GB 沿用原始脚本，应根据组装分区节点的实际内存和允许的并发数量进行调整。

minibwa 可能额外创建两个 I/O 线程，因此 mapping worker 数计算为 `max(1, threads - 2)`。BAM 排序和索引单独运行，`samtools -@` 使用 `threads - 1`。

中间 SAM 文件被标记为 `temp()`，排序结束后会删除，但运行期间仍需足够的临时磁盘空间。使用进程池的步骤会限制 BLAS 和 OpenMP 库线程，避免嵌套并发导致实际线程数超过申请值。

参见 [minibwa 线程说明](https://github.com/lh3/minibwa/blob/master/minibwa.1)。

## 执行、续跑和日志

以下命令均应从工作流目录执行。配置真实 FASTQ 路径后，启动分析：

```bash
snakemake \
  --workflow-profile slurm \
  --jobs 20
```

`--jobs` 限制同时在途的作业数，每条规则的 CPU 请求由其 `threads` 决定。长期运行建议在 `tmux` 中启动 Snakemake。中断后重新执行相同命令即可续跑，profile 已启用 `rerun-incomplete`。Profile 同时启用了 `keep-going`：作业失败只会终止依赖它的样本分支，其他样本继续运行；运行结束后会列出失败作业并以非零状态退出。失败作业会重试两次；`slurm-requeue` 让 Slurm 在集群允许时自动重新排队。

运行结束或失败后，可用以下命令生成自包含的 HTML 汇总报告（运行统计、来源信息与已有结果）：

```bash
snakemake --report report.html
```

资源覆盖示例：

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

日志位置：

- 外部程序日志：`logs/<rule>/<sample>.log`
- Slurm 作业日志：`logs/slurm/`
- 数据库准备日志：`results/logs/databases/`

作业状态通过 Slurm 记账系统（`sacct`）查询。`FAILED`、`TIMEOUT`、`OUT_OF_MEMORY` 等终止失败状态会被判定为作业失败；运行期间发生故障的节点会被记录、从后续提交中排除，并在运行结束时报告。

Slurm 作业名为工作流运行 UUID；每个作业的 rule 与 wildcards 记录在 Slurm 的 Comment 字段中（`rule_<rule>_wildcards_<wildcards>`）。可用以下命令查看带可读信息的作业：

```bash
squeue -u "$USER" -o "%.10i %.32j %.45k %.10T %.10M"
```

## 分析参数与输出

### 质量控制

fastp 默认启用双端 adapter 检测，合格碱基阈值为 Q20，最短 read 长度为 50，不执行宿主去除。

质控参数在 `qc` 中配置。参见 [fastp 文档](https://github.com/OpenGene/fastp)。

### 组装

每个样本独立使用 **metaSPAdes** 的 `--only-assembler` 模式组装。默认 k-mer 为 21、33、55、77、99 和 127；`assembly.kmers` 与 `assembly.memory_gb` 分别设置 k-mer 列表和 metaSPAdes 内存上限（`-m`）。组装结果输出到 `02_assembly/<sample>/scaffolds.fasta`。

参见 [SPAdes 文档](https://github.com/ablab/spades)。

### 比对

minibwa 对组装结果建立索引，质控后的 reads 回贴到组装序列，随后由 samtools 排序并建立索引。mapping worker 数为 `max(1, threads - 2)`，排序和索引使用 `threads - 1`。输出为 `03_mapping/<sample>/assembly.bam` 及其 `.bai` 索引，该 BAM 会被分箱、RefineM 和 CoverM 复用。

参见 [minibwa 文档](https://github.com/lh3/minibwa)。

### 分箱

三种分箱工具在每个样本上并行运行，每个任务开始前都会校验 GPU：

- **COMEBin**：对组装序列和 BAM 进行对比式多视图表示学习，并且需要 CheckM 数据库。
- **SemiBin2**：使用全局环境模型运行 `single_easy_bin`。
- **MetaCAT**：依次执行 coverage 计算、seed 和 cluster。

各工具的输出会在 `04_binning/<sample>/{comebin,semibin2,metacat}/` 下统一为 FASTA（`.fa`），contig ID 保持不变。

参见 [COMEBin](https://github.com/ziyewang/COMEBin)、[SemiBin2](https://github.com/BigDataBiology/SemiBin) 和 [MetaCAT](https://github.com/liu-congcong/MetaCAT) 仓库。

### Bin 精炼

Binette 通过多套 bin 的交集、差集和并集生成候选，并使用 CheckM2 评分。

`refinement` 控制完整度、污染度、污染评分权重和 bin 长度范围。

参见 [Binette 固定版本的参数实现](https://github.com/genotoul-bioinfo/Binette/blob/v1.2.1/binette/main.py)。

### RefineM 过滤

RefineM 默认执行以下三个步骤：

```text
scaffold_stats -> outliers -> filter_bins
```

输入包括组装 FASTA、Binette bins 和原始组装 BAM。默认过滤标准为：

- GC 和四核苷酸分布使用第 98 百分位阈值
- 覆盖度平均绝对百分比误差阈值为 50%
- contig 满足任意已启用的离群标准时即被过滤
- 单样本覆盖度分析通过阈值 `-2` 关闭相关系数过滤

可在 `refinem` 中修改这些参数，或设置 `enabled: false` 关闭过滤。空 bin 会从最终结果中删除并记录在 `bin_retention.tsv` 中；如果没有任何 bin 保留，规则将失败。

参见 [RefineM 官方污染识别流程](https://github.com/donovan-h-parks/RefineM#identifying-potential-contamination)。

### 最终质量评估

CheckM 和 CheckM2 会对 **RefineM 过滤后**的最终 MAGs 重新评估。Binette 的中间质量表只描述过滤前的 bins。

由于 RefineM 可能同时降低污染度和完整度，下游判断应以过滤后的 CheckM 和 CheckM2 报告为准。

可以在 `analysis` 中关闭以下分支：

- GTDB-Tk 分类注释
- 基因预测
- 独立 CheckM 评估
- 独立 CheckM2 评估

关闭独立 CheckM2 分支不会移除 Binette 对 CheckM2 数据库的依赖。关闭独立 CheckM 分支也不会移除 COMEBin 对 CheckM1 数据库的依赖。

### 分类注释

GTDB-Tk 使用 `classify_wf --skip_ani_screen` 基于固定的 GTDB R232 版本对最终 MAGs 进行分类注释，pplacer 线程数由 `gtdbtk.pplacer_threads` 限制。结果输出到 `07_taxonomy/<sample>/`。

参见 [GTDB-Tk 文档](https://ecogenomics.github.io/GTDBTk/)。

### 基因预测

基因预测使用 **Pyrodigal 3.7.1**。每个最终 MAG 分别使用 `-p single` 训练和预测，contig 通过 `-j {threads} --pool thread` 并行处理。

每个 MAG 输出：

- 蛋白序列：`.faa`
- 基因核酸序列：`.ffn`
- 基因注释：`.gff`

默认通过 `workflow/envs/pyrodigal.yaml` 管理 Pyrodigal，也可以使用 `environments.pyrodigal` 指定已有环境。

参见 [Pyrodigal 3.7.1 命令行文档](https://pyrodigal.readthedocs.io/en/v3.7.1/guide/cli.html)。

### 丰度计算

CoverM 基于组装 BAM 以两种模式计算丰度：`coverm contig`，以及针对最终 MAGs 的 `coverm genome`。两者都输出 trimmed mean 覆盖度、长度、count、RPKM 和 TPM；genome 模式还会输出相对丰度，并使用 `--min-covered-fraction 0`。输出为 `09_abundance/<sample>/contig.tsv` 和 `09_abundance/<sample>/genome.tsv`。

参见 [CoverM 文档](https://github.com/wwood/CoverM)。

### 输出目录结构

| 路径 | 内容 |
| --- | --- |
| `01_qc/<sample>/` | fastp 过滤后的 reads 以及 HTML/JSON 报告 |
| `02_assembly/<sample>/scaffolds.fasta` | metaSPAdes 组装结果 |
| `03_mapping/<sample>/` | minibwa 索引以及排序后的 BAM/BAI 文件 |
| `04_binning/<sample>/<binner>/` | 三种分箱工具的原始结果和统一格式的 `.fa` bins |
| `05_refinement/<sample>/` | Binette `final_bins/` 和过滤前质量表 |
| `05_refinem/<sample>/` | scaffold 统计、离群表、过滤后的 bins 和保留记录 |
| `06_mags/<sample>/*.fna` | 所有下游分支使用的最终 MAGs |
| `07_taxonomy/<sample>/` | GTDB-Tk 分类结果 |
| `08_genes/<sample>/` | 每个 MAG 的蛋白 `.faa`、基因 `.ffn` 和 `.gff` 文件 |
| `09_abundance/<sample>/{contig,genome}.tsv` | CoverM 丰度表 |
| `10_checkm/<sample>/quality_report.tsv` | 最终 MAGs 的 CheckM 评估结果 |
| `11_checkm2/<sample>/quality_report.tsv` | 最终 MAGs 的 CheckM2 质量报告 |

每个样本分别进行组装、分箱和丰度计算，不执行跨样本去冗余或交叉回贴。

CoverM 使用与分箱阶段相同的组装 BAM。FASTA 标准化会保留 contig ID，以确保其与 BAM reference 一致。

COMEBin 使用独立的 FASTA 副本，避免 marker 文件修改共享组装目录。如果任一分箱工具没有产生 bins，对应规则将失败，不会让空目录进入下游分析。

Snakemake 使用 `directory()` 管理部分完整工具输出目录，重跑时会重建这些目录。请勿将原始 reads 或重要数据的唯一副本放入其中。

手动修改受管理目录中的单个文件可能不会更新目录时间戳。需要识别此类修改时，请对相应规则使用 `--forcerun`。

## 许可证

本项目采用 GNU General Public License v3.0 许可协议，完整文本见 [LICENSE](LICENSE)。
