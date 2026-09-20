rule refinem_stats:
    input:
        refinement=rules.refinement.output.refinement,
        assembly=rules.assembly.output.assembly,
        bam=rules.sort_bam.output.bam,
        bai=rules.sort_bam.output.bai
    output:
        stats=directory(REFINEM + "/stats")
    threads: setting("refinem_stats", "threads")
    resources:
        partition=setting("refinem_stats", "partition"),
        runtime=setting("refinem_stats", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        min_alignment=config["refinem"]["min_alignment_fraction"],
        max_edit=config["refinem"]["max_edit_distance_fraction"]
    conda: ENVS["refinem"]
    log: "logs/refinem_stats/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            refinem scaffold_stats -x fa -c {threads} \
                --cov_min_align {params.min_alignment} --cov_max_edit_dist {params.max_edit} \
                {input.assembly:q}/scaffolds.fasta {input.refinement:q}/final_bins \
                {output.stats:q} {input.bam:q}
            require_nonempty {output.stats:q}/scaffold_stats.tsv
        }} > {log:q} 2>&1
        """


rule refinem_outliers:
    input:
        stats=rules.refinem_stats.output.stats
    output:
        outliers=directory(REFINEM + "/outliers")
    threads: setting("refinem_outliers", "threads")
    resources:
        partition=setting("refinem_outliers", "partition"),
        runtime=setting("refinem_outliers", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        gc=config["refinem"]["gc_percentile"],
        td=config["refinem"]["td_percentile"],
        cov_error=config["refinem"]["coverage_percent_error"],
        cov_corr=config["refinem"]["coverage_correlation"],
        report_type=config["refinem"]["report_type"]
    conda: ENVS["refinem"]
    log: "logs/refinem_outliers/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        {{
            refinem outliers {input.stats:q}/scaffold_stats.tsv {output.outliers:q} \
                --gc_perc {params.gc} --td_perc {params.td} --cov_perc {params.cov_error} \
                --cov_corr {params.cov_corr} --report_type {params.report_type:q}
            # A header-only table is valid when no scaffold is an outlier.
            require_nonempty {output.outliers:q}/outliers.tsv
        }} > {log:q} 2>&1
        """


rule refinem_filter:
    input:
        refinement=rules.refinement.output.refinement,
        outliers=rules.refinem_outliers.output.outliers
    output:
        filtered=directory(REFINEM + "/filtered")
    threads: setting("refinem_filter", "threads")
    resources:
        partition=setting("refinem_filter", "partition"),
        runtime=setting("refinem_filter", "runtime"),
        slurm_account=config["slurm_account"]
    conda: ENVS["refinem"]
    log: "logs/refinem_filter/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        {{
            refinem filter_bins -x fa {input.refinement:q}/final_bins \
                {input.outliers:q}/outliers.tsv {output.filtered:q}/raw
            # Keep unchanged bins too; do not pass --modified_only.
            {PYTHON:q} {BIN_UTILS:q} normalize {output.filtered:q}/raw \
                {output.filtered:q}/bins --extension fa --skip-empty \
                --report {output.filtered:q}/bin_retention.tsv
        }} > {log:q} 2>&1
        """
