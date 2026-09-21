"""Optional dRep dereplication of per-sample and pooled MAGs."""

if config.get("drep", {}).get("sample", False):
    rule drep_checkm2:
        input:
            mags=MAGS,
            database=database_ready("checkm2")
        output:
            checkm2=directory(ROOT + "/06_drep/{sample}/checkm2")
        threads: setting("checkm2", "threads")
        resources:
            slurm_partition=setting("checkm2", "partition"),
            runtime=setting("checkm2", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            database_path=checkm2_database_file(),
            converter=str(WORKFLOW_ROOT / "workflow/scripts/drep_genome_info.py")
        conda: ENVS["checkm2"]
        log: "logs/drep_checkm2/{sample}.log"
        shell:
            r"""
            limit_threads 1
            {{
                database_path={params.database_path:q}
                if [[ -n "$database_path" ]]; then export CHECKM2DB="$database_path"; fi
                checkm2 predict -i {input.mags:q} -o {output.checkm2:q} -t {threads} -x fna --allmodels
                require_nonempty {output.checkm2:q}/quality_report.tsv
                {PYTHON:q} {params.converter:q} --report {output.checkm2:q}/quality_report.tsv \
                    --genomes {input.mags:q} --output {output.checkm2:q}/genome_info.csv
                require_nonempty {output.checkm2:q}/genome_info.csv
            }} > {log:q} 2>&1
            """

    rule drep_sample:
        input:
            mags=MAGS,
            quality=rules.drep_checkm2.output.checkm2
        output:
            mags=directory(ROOT + "/06_drep/{sample}/mags"),
            workdir=directory(ROOT + "/06_drep/{sample}/drep")
        threads: setting("drep", "threads")
        resources:
            slurm_partition=setting("drep", "partition"),
            runtime=setting("drep", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            ani=config["drep"]["ani"],
            coverage=config["drep"]["coverage"],
            completeness=config["drep"]["completeness"],
            contamination=config["drep"]["contamination"],
            min_length=config["drep"]["min_length"]
        conda: ENVS["drep"]
        log: "logs/drep_sample/{sample}.log"
        shell:
            r"""
            limit_threads {threads}
            {{
                genome_list={output.workdir:q}.genomes.txt
                ls {input.mags:q}/*.fna > "$genome_list"
                dRep dereplicate {output.workdir:q} -p {threads} -g "$genome_list" \
                    --genomeInfo {input.quality:q}/genome_info.csv \
                    -sa {params.ani} -nc {params.coverage} -comp {params.completeness} \
                    -con {params.contamination} -l {params.min_length}
                rm -f "$genome_list"
                mkdir -p {output.mags:q}
                cp {output.workdir:q}/dereplicated_genomes/*.fna {output.mags:q}/
                shopt -s nullglob
                genomes=({output.mags:q}/*.fna)
                (( ${{#genomes[@]}} > 0 )) || {{ echo "No dereplicated genomes remain" >&2; exit 1; }}
            }} > {log:q} 2>&1
            """

if config.get("drep", {}).get("cross_sample", False):
    rule drep_cross_checkm2:
        input:
            mags=expand(MAGS_SOURCE, sample=SAMPLES),
            database=database_ready("checkm2")
        output:
            genomes=directory(ROOT + "/12_drep/input"),
            checkm2=directory(ROOT + "/12_drep/checkm2")
        threads: setting("checkm2", "threads")
        resources:
            slurm_partition=setting("checkm2", "partition"),
            runtime=setting("checkm2", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            database_path=checkm2_database_file(),
            converter=str(WORKFLOW_ROOT / "workflow/scripts/drep_genome_info.py")
        conda: ENVS["checkm2"]
        log: "logs/drep_cross_checkm2.log"
        shell:
            r"""
            limit_threads 1
            {{
                mkdir -p {output.genomes:q}
                for source in {input.mags:q}; do
                    for genome in "$source"/*.fna; do
                        link={output.genomes:q}/$(basename "$genome")
                        if [[ -e "$link" || -L "$link" ]]; then
                            echo "Duplicate MAG basename: $(basename "$genome")" >&2
                            exit 1
                        fi
                        ln -s "$(readlink -f "$genome")" "$link"
                    done
                done
                database_path={params.database_path:q}
                if [[ -n "$database_path" ]]; then export CHECKM2DB="$database_path"; fi
                checkm2 predict -i {output.genomes:q} -o {output.checkm2:q} -t {threads} -x fna --allmodels
                require_nonempty {output.checkm2:q}/quality_report.tsv
                {PYTHON:q} {params.converter:q} --report {output.checkm2:q}/quality_report.tsv \
                    --genomes {output.genomes:q} --output {output.checkm2:q}/genome_info.csv
                require_nonempty {output.checkm2:q}/genome_info.csv
            }} > {log:q} 2>&1
            """

    rule drep_cross:
        input:
            genomes=rules.drep_cross_checkm2.output.genomes,
            quality=rules.drep_cross_checkm2.output.checkm2
        output:
            mags=directory(ROOT + "/12_drep/mags"),
            workdir=directory(ROOT + "/12_drep/drep")
        threads: setting("drep_cross", "threads")
        resources:
            slurm_partition=setting("drep_cross", "partition"),
            runtime=setting("drep_cross", "runtime"),
            slurm_account=config["slurm_account"]
        params:
            ani=config["drep"]["ani"],
            coverage=config["drep"]["coverage"],
            completeness=config["drep"]["completeness"],
            contamination=config["drep"]["contamination"],
            min_length=config["drep"]["min_length"]
        conda: ENVS["drep"]
        log: "logs/drep_cross.log"
        shell:
            r"""
            limit_threads {threads}
            {{
                genome_list={output.workdir:q}.genomes.txt
                ls {input.genomes:q}/*.fna > "$genome_list"
                dRep dereplicate {output.workdir:q} -p {threads} -g "$genome_list" \
                    --genomeInfo {input.quality:q}/genome_info.csv \
                    -sa {params.ani} -nc {params.coverage} -comp {params.completeness} \
                    -con {params.contamination} -l {params.min_length}
                rm -f "$genome_list"
                mkdir -p {output.mags:q}
                cp {output.workdir:q}/dereplicated_genomes/*.fna {output.mags:q}/
                shopt -s nullglob
                genomes=({output.mags:q}/*.fna)
                (( ${{#genomes[@]}} > 0 )) || {{ echo "No dereplicated genomes remain" >&2; exit 1; }}
            }} > {log:q} 2>&1
            """
