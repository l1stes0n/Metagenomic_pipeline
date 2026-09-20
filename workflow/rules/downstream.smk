rule gtdbtk:
    input:
        mags=rules.prepare_mags.output.mags,
        database=database_ready("gtdbtk")
    output:
        taxonomy=directory(ROOT + "/07_taxonomy/{sample}")
    threads: setting("gtdbtk", "threads")
    resources:
        slurm_partition=setting("gtdbtk", "partition"),
        runtime=setting("gtdbtk", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        data_path=database_dir("gtdbtk"),
        pplacer_threads=lambda wc, threads: min(threads, config["gtdbtk"]["pplacer_threads"])
    conda: ENVS["gtdbtk"]
    log: "logs/gtdbtk/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            data_path={params.data_path:q}
            if [[ -n "$data_path" ]]; then export GTDBTK_DATA_PATH="$data_path"; fi
            gtdbtk classify_wf --genome_dir {input.mags:q} --out_dir {output.taxonomy:q} \
                --extension fna --skip_ani_screen --cpus {threads} --pplacer_cpus {params.pplacer_threads}
            shopt -s nullglob
            reports=({output.taxonomy:q}/gtdbtk.*.summary.tsv)
            (( ${{#reports[@]}} > 0 )) || {{ echo "GTDB-Tk produced no summary" >&2; exit 1; }}
            require_nonempty "${{reports[@]}}"
        }} > {log:q} 2>&1
        """


rule genes:
    input:
        mags=rules.prepare_mags.output.mags
    output:
        genes=directory(ROOT + "/08_genes/{sample}")
    threads: setting("genes", "threads")
    resources:
        slurm_partition=setting("genes", "partition"),
        runtime=setting("genes", "runtime"),
        slurm_account=config["slurm_account"]
    conda: ENVS["pyrodigal"]
    log: "logs/genes/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            mkdir -p {output.genes:q}
            shopt -s nullglob
            genomes=({input.mags:q}/*.fna)
            (( ${{#genomes[@]}} > 0 )) || {{ echo "No MAGs for gene prediction" >&2; exit 1; }}
            # Train each MAG independently; parallelize its contigs within the job allocation.
            for genome in "${{genomes[@]}}"; do
                name=$(basename "$genome" .fna)
                pyrodigal -j {threads} --pool thread -p single -i "$genome" -a {output.genes:q}/"$name.faa" \
                    -d {output.genes:q}/"$name.ffn" -o {output.genes:q}/"$name.gff" -f gff
                require_nonempty {output.genes:q}/"$name.faa" {output.genes:q}/"$name.ffn" {output.genes:q}/"$name.gff"
            done
        }} > {log:q} 2>&1
        """


rule coverm_contig:
    input:
        bam=rules.sort_bam.output.bam,
        bai=rules.sort_bam.output.bai
    output:
        table=ROOT + "/09_abundance/{sample}/contig.tsv"
    threads: setting("coverm_contig", "threads")
    resources:
        slurm_partition=setting("coverm_contig", "partition"),
        runtime=setting("coverm_contig", "runtime"),
        slurm_account=config["slurm_account"]
    conda: ENVS["coverm"]
    log: "logs/coverm_contig/{sample}.log"
    shell:
        r"""
        limit_threads 1
        coverm contig -b {input.bam:q} -t {threads} -m trimmed_mean length count rpkm tpm \
            -o {output.table:q} > {log:q} 2>&1
        require_nonempty {output.table:q}
        """


rule coverm_genome:
    input:
        bam=rules.sort_bam.output.bam,
        bai=rules.sort_bam.output.bai,
        mags=rules.prepare_mags.output.mags
    output:
        table=ROOT + "/09_abundance/{sample}/genome.tsv"
    threads: setting("coverm_genome", "threads")
    resources:
        slurm_partition=setting("coverm_genome", "partition"),
        runtime=setting("coverm_genome", "runtime"),
        slurm_account=config["slurm_account"]
    conda: ENVS["coverm"]
    log: "logs/coverm_genome/{sample}.log"
    shell:
        r"""
        limit_threads 1
        coverm genome -b {input.bam:q} -d {input.mags:q} -x fna \
            -m relative_abundance trimmed_mean length count rpkm tpm \
            --min-covered-fraction 0 -t {threads} -o {output.table:q} > {log:q} 2>&1
        require_nonempty {output.table:q}
        """


rule checkm:
    input:
        mags=rules.prepare_mags.output.mags,
        database=database_ready("checkm")
    output:
        qc=directory(ROOT + "/10_checkm/{sample}")
    threads: setting("checkm", "threads")
    resources:
        slurm_partition=setting("checkm", "partition"),
        runtime=setting("checkm", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        data_path=database_dir("checkm")
    conda: ENVS["checkm"]
    log: "logs/checkm/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            export CHECKM_DATA_PATH={params.data_path:q}
            checkm lineage_wf -x fna -t {threads} --pplacer_threads {threads} \
                {input.mags:q} {output.qc:q}
            checkm qa --tab_table -o 2 -f {output.qc:q}/quality_report.tsv \
                {output.qc:q}/lineage.ms {output.qc:q}
            require_nonempty {output.qc:q}/quality_report.tsv
        }} > {log:q} 2>&1
        """


rule checkm2:
    input:
        mags=rules.prepare_mags.output.mags,
        database=database_ready("checkm2")
    output:
        qc=directory(ROOT + "/11_checkm2/{sample}")
    threads: setting("checkm2", "threads")
    resources:
        slurm_partition=setting("checkm2", "partition"),
        runtime=setting("checkm2", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        database_path=checkm2_database_file()
    conda: ENVS["checkm2"]
    log: "logs/checkm2/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            database_path={params.database_path:q}
            if [[ -n "$database_path" ]]; then export CHECKM2DB="$database_path"; fi
            checkm2 predict -i {input.mags:q} -o {output.qc:q} -t {threads} -x fna --allmodels
            require_nonempty {output.qc:q}/quality_report.tsv
            {PYTHON:q} {BIN_UTILS:q} checkm2-csv {output.qc:q}/quality_report.tsv \
                {input.mags:q} {output.qc:q}/genomeInformation.csv
        }} > {log:q} 2>&1
        """
