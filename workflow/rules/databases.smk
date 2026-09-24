"""Database preparation independent of sample analysis and biological tools."""
import json

DATABASE_NAMES = ("gtdbtk", "checkm", "checkm2")
DATABASE_SCRIPT = str(WORKFLOW_ROOT / "workflow/scripts/prepare_database.py")


def database_dir(name):
    return str(Path(config["databases"][name]["path"]).expanduser().resolve())


def database_ready(name):
    return ROOT + "/00_databases/" + name + ".ready.json"


def checkm2_database_file():
    return database_dir("checkm2") + "/uniref100.KO.1.dmnd"


def bakta_minor():
    return str(config["databases"]["bakta"]["version"]).split(".")[-1]


rule prepare_databases:
    input:
        [database_ready(name) for name in DATABASE_NAMES]


rule prepare_database:
    output:
        ROOT + "/00_databases/{database}.ready.json"
    wildcard_constraints:
        database="gtdbtk|checkm|checkm2"
    params:
        script=DATABASE_SCRIPT,
        spec=lambda wc: json.dumps(config["databases"][wc.database], sort_keys=True)
    threads: setting("prepare_database", "threads")
    resources:
        slurm_partition=setting("prepare_database", "partition"),
        runtime=setting("prepare_database", "runtime"),
        gpus=0,
        slurm_account=config.get("slurm_account", "")
    log:
        ROOT + "/logs/databases/{database}.log"
    shell:
        r"""
        mkdir -p "$(dirname {log:q})"
        {PYTHON:q} {params.script:q} --name {wildcards.database:q} \
            --spec {params.spec:q} --marker {output:q} > {log:q} 2>&1
        """


rule prepare_bakta:
    output:
        database_ready("bakta")
    params:
        spec=lambda wc: json.dumps(config["databases"]["bakta"], sort_keys=True),
        script=DATABASE_SCRIPT,
        database=database_dir("bakta"),
        parent=lambda wc: str(Path(database_dir("bakta")).parent),
        type=config["databases"]["bakta"]["type"],
        mode=config["databases"]["bakta"]["mode"],
        minor=bakta_minor(),
    threads: setting("prepare_database", "threads")
    resources:
        slurm_partition=setting("prepare_database", "partition"),
        runtime=setting("prepare_database", "runtime"),
        slurm_account=config.get("slurm_account", "")
    conda: ENVS["bakta"]
    log:
        ROOT + "/logs/databases/bakta.log"
    shell:
        r"""
        mkdir -p "$(dirname {log:q})" {params.parent:q}
        if [[ "{params.mode}" == "download" && ! -s {params.database:q}/version.json ]]; then
            bakta_db download --output {params.parent:q} --type {params.type:q} \
                --minor {params.minor} > {log:q} 2>&1
        fi
        {PYTHON:q} {params.script:q} --name bakta --spec {params.spec:q} \
            --marker {output:q} --validate-only >> {log:q} 2>&1
        """
