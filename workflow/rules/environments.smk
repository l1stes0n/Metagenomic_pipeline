"""Optional environment-only target, independent of FASTQ and database inputs."""

rule prepare_environments:
    input:
        expand(ROOT + "/00_environments/{tool}.ready.json", tool=ACTIVE_TOOLS)


rule environment_ready:
    output:
        ROOT + "/00_environments/{tool}.ready.json"
    wildcard_constraints:
        tool="|".join(ACTIVE_TOOLS)
    threads: setting("environment_ready", "threads")
    resources:
        slurm_partition=setting("environment_ready", "partition"),
        runtime=setting("environment_ready", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        checker=str(WORKFLOW_ROOT / "workflow/scripts/check_environment.py"),
        python=PYTHON,
        specification=lambda wc: ENVS[wc.tool],
        executables=lambda wc: list(ACTIVE_TOOLS[wc.tool])
    conda:
        lambda wc: ENVS[wc.tool]
    log:
        "logs/environments/{tool}.log"
    shell:
        r"""
        limit_threads {threads}
        {params.python:q} {params.checker:q} --tool {wildcards.tool:q} \
            --specification {params.specification:q} --output {output:q} \
            --executables {params.executables:q} > {log:q} 2>&1
        """
