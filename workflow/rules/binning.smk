if "comebin" in BINNERS:
    rule comebin:
        input:
            assembly=rules.assembly.output.assembly,
            bam=rules.sort_bam.output.bam,
            bai=rules.sort_bam.output.bai,
            database=database_ready("checkm")
        output:
            bins=directory(BINNING + "/comebin")
        threads: setting("comebin", "threads")
        resources:
            slurm_partition=setting("comebin", "partition"),
            runtime=setting("comebin", "runtime"),
            gpu=setting("comebin", "gpus"),
            slurm_account=config["slurm_account"]
        params:
            bamdir=lambda wc, input: str(Path(input.bam).parent.resolve()),
            checkm_db=database_dir("checkm"),
            gpu_check=str(WORKFLOW_ROOT / "workflow/scripts/check_gpu.py")
        conda: ENVS["comebin"]
        log: "logs/comebin/{sample}.log"
        shell:
            r"""
            limit_threads 1
            {{
                python {params.gpu_check:q} --backend torch
                export CHECKM_DATA_PATH={params.checkm_db:q}
                mkdir -p {output.bins:q}
                # COMEBin creates marker files next to its FASTA input.
                cp {input.assembly:q}/scaffolds.fasta {output.bins:q}/scaffolds.fasta
                run_comebin.sh -a {output.bins:q}/scaffolds.fasta -p {params.bamdir:q} \
                    -o {output.bins:q}/raw -t {threads}
                {PYTHON:q} {BIN_UTILS:q} normalize \
                    {output.bins:q}/raw/comebin_res/comebin_res_bins {output.bins:q}/comebin_bins --extension fa
            }} > {log:q} 2>&1
            """


if "semibin2" in BINNERS:
    rule semibin2:
        input:
            assembly=rules.assembly.output.assembly,
            bam=rules.sort_bam.output.bam,
            bai=rules.sort_bam.output.bai
        output:
            bins=directory(BINNING + "/semibin2")
        threads: setting("semibin2", "threads")
        resources:
            slurm_partition=setting("semibin2", "partition"),
            runtime=setting("semibin2", "runtime"),
            gpu=setting("semibin2", "gpus"),
            slurm_account=config["slurm_account"]
        params:
            gpu_check=str(WORKFLOW_ROOT / "workflow/scripts/check_gpu.py")
        conda: ENVS["semibin2"]
        log: "logs/semibin2/{sample}.log"
        shell:
            r"""
            limit_threads 1
            {{
                python {params.gpu_check:q} --backend torch
                SemiBin2 single_easy_bin --input-fasta {input.assembly:q}/scaffolds.fasta \
                    --input-bam {input.bam:q} --environment global \
                    --output {output.bins:q}/raw --threads {threads}
                {PYTHON:q} {BIN_UTILS:q} normalize \
                    {output.bins:q}/raw/output_bins {output.bins:q}/semibin2_bins --extension fa
            }} > {log:q} 2>&1
            """


if "metacat" in BINNERS:
    rule metacat:
        input:
            assembly=rules.assembly.output.assembly,
            bam=rules.sort_bam.output.bam,
            bai=rules.sort_bam.output.bai
        output:
            bins=directory(BINNING + "/metacat")
        threads: setting("metacat", "threads")
        resources:
            slurm_partition=setting("metacat", "partition"),
            runtime=setting("metacat", "runtime"),
            gpu=setting("metacat", "gpus"),
            slurm_account=config["slurm_account"]
        params:
            gpu_check=str(WORKFLOW_ROOT / "workflow/scripts/check_gpu.py")
        conda: ENVS["metacat"]
        log: "logs/metacat/{sample}.log"
        shell:
            r"""
            limit_threads 1
            {{
                python {params.gpu_check:q} --backend cupy
                mkdir -p {output.bins:q}/raw {output.bins:q}/tmp
                MetaCAT coverage --bam {input.bam:q} --output {output.bins:q}/coverage.tsv \
                    --threads-index {threads} --threads-count {threads}
                MetaCAT seed --fasta {input.assembly:q}/scaffolds.fasta \
                    --output {output.bins:q}/seeds.tsv --temp {output.bins:q}/tmp --threads {threads}
                MetaCAT cluster --fasta {input.assembly:q}/scaffolds.fasta \
                    --coverage {output.bins:q}/coverage.tsv --seed {output.bins:q}/seeds.tsv \
                    --output {output.bins:q}/raw/bin --threads {threads}
                {PYTHON:q} {BIN_UTILS:q} normalize {output.bins:q}/raw {output.bins:q}/metacat_bins --extension fa
            }} > {log:q} 2>&1
            """


if "metabat2" in BINNERS or "maxbin2" in BINNERS:
    rule binning_depth:
        input:
            bam=rules.sort_bam.output.bam,
            bai=rules.sort_bam.output.bai
        output:
            depth=BINNING + "/depth/depth.txt",
            abundance=BINNING + "/depth/abundance.tsv"
        threads: setting("binning_depth", "threads")
        resources:
            slurm_partition=setting("binning_depth", "partition"),
            runtime=setting("binning_depth", "runtime"),
            slurm_account=config["slurm_account"]
        conda: ENVS["metabat2"]
        log: "logs/binning_depth/{sample}.log"
        shell:
            r"""
            limit_threads 1
            {{
                jgi_summarize_bam_contig_depths --outputDepth {output.depth:q} {input.bam:q}
                awk -F'\t' 'NR>1 {{print $1 "\t" $3}}' {output.depth:q} > {output.abundance:q}
                require_nonempty {output.depth:q} {output.abundance:q}
            }} > {log:q} 2>&1
            """


if "metabat2" in BINNERS:
    rule metabat2:
        input:
            assembly=rules.assembly.output.assembly,
            depth=rules.binning_depth.output.depth
        output:
            bins=directory(BINNING + "/metabat2")
        threads: setting("metabat2", "threads")
        resources:
            slurm_partition=setting("metabat2", "partition"),
            runtime=setting("metabat2", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            min_contig_len=config["binning"]["metabat2_min_contig_len"]
        conda: ENVS["metabat2"]
        log: "logs/metabat2/{sample}.log"
        shell:
            r"""
            limit_threads {threads}
            {{
                mkdir -p {output.bins:q}/raw
                metabat2 -i {input.assembly:q}/scaffolds.fasta -a {input.depth:q} \
                    -o {output.bins:q}/raw/bin -m {params.min_contig_len} -t {threads}
                {PYTHON:q} {BIN_UTILS:q} normalize {output.bins:q}/raw \
                    {output.bins:q}/metabat2_bins --extension fa
            }} > {log:q} 2>&1
            """


if "maxbin2" in BINNERS:
    rule maxbin2:
        input:
            assembly=rules.assembly.output.assembly,
            abundance=rules.binning_depth.output.abundance
        output:
            bins=directory(BINNING + "/maxbin2")
        threads: setting("maxbin2", "threads")
        resources:
            slurm_partition=setting("maxbin2", "partition"),
            runtime=setting("maxbin2", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            min_contig_length=config["binning"]["maxbin2_min_contig_length"]
        conda: ENVS["maxbin2"]
        log: "logs/maxbin2/{sample}.log"
        shell:
            r"""
            limit_threads {threads}
            {{
                mkdir -p {output.bins:q}/raw
                run_MaxBin.pl -contig {input.assembly:q}/scaffolds.fasta \
                    -abund {input.abundance:q} -out {output.bins:q}/raw/maxbin \
                    -thread {threads} -min_contig_length {params.min_contig_length}
                {PYTHON:q} {BIN_UTILS:q} normalize {output.bins:q}/raw \
                    {output.bins:q}/maxbin2_bins --extension fa
            }} > {log:q} 2>&1
            """


BINNER_SETS = []
if "comebin" in BINNERS:
    BINNER_SETS.append((rules.comebin.output.bins, "comebin_bins"))
if "semibin2" in BINNERS:
    BINNER_SETS.append((rules.semibin2.output.bins, "semibin2_bins"))
if "metacat" in BINNERS:
    BINNER_SETS.append((rules.metacat.output.bins, "metacat_bins"))
if "metabat2" in BINNERS:
    BINNER_SETS.append((rules.metabat2.output.bins, "metabat2_bins"))
if "maxbin2" in BINNERS:
    BINNER_SETS.append((rules.maxbin2.output.bins, "maxbin2_bins"))


rule refinement:
    input:
        bins=[b for b, _ in BINNER_SETS],
        assembly=rules.assembly.output.assembly,
        database=database_ready("checkm2")
    output:
        refinement=directory(REFINEMENT)
    threads: setting("refinement", "threads")
    resources:
        slurm_partition=setting("refinement", "partition"),
        runtime=setting("refinement", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        bin_dirs=[str(Path(b) / s) for b, s in BINNER_SETS],
        completeness=threshold("completeness"),
        contamination=threshold("contamination"),
        checkm2_db=checkm2_database_file(),
        weight=config["refinement"]["contamination_weight"],
        min_length=config["refinement"]["min_length"],
        max_length=config["refinement"]["max_length"]
    conda: ENVS["binette"]
    log: "logs/refinement/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            binette --bin_dirs {params.bin_dirs:q} --contigs {input.assembly:q}/scaffolds.fasta \
                --outdir {output.refinement:q} --threads {threads} --checkm2_db {params.checkm2_db:q} \
                --min_completeness {params.completeness:q} --max_contamination {params.contamination:q} \
                --contamination_weight {params.weight} --min_length {params.min_length} \
                --max_length {params.max_length} --prefix {wildcards.sample:q}
            require_nonempty {output.refinement:q}/final_bins_quality_reports.tsv
        }} > {log:q} 2>&1
        """


rule prepare_mags:
    input:
        bins=(REFINEM + "/filtered" if config["refinem"]["enabled"] else REFINEMENT)
    output:
        mags=directory(MAGS)
    threads: setting("prepare_mags", "threads")
    resources:
        slurm_partition=setting("prepare_mags", "partition"),
        runtime=setting("prepare_mags", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        source=lambda wc, input: str(Path(input.bins) / ("bins" if config["refinem"]["enabled"] else "final_bins"))
    log: "logs/prepare_mags/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        {PYTHON:q} {BIN_UTILS:q} normalize \
            {params.source:q} {output.mags:q} --extension fna > {log:q} 2>&1
        """
