"""Database preparation independent of sample analysis and biological tools."""
import json

BAKTA_ARCHIVES = {"light": "db-light.tar.xz", "full": "db.tar.xz"}
DATABASE_NAMES = ("gtdbtk", "checkm", "checkm2")
if BAKTA_ENABLED:
    DATABASE_NAMES += ("bakta",)
DATABASE_SCRIPT = str(WORKFLOW_ROOT / "workflow/scripts/prepare_database.py")


def database_spec(name):
    if name not in config["databases"]:
        raise ValueError(f"databases.{name} is required")
    return json.dumps(config["databases"][name], sort_keys=True)


def database_dir(name):
    if name not in config["databases"] or not str(config["databases"][name].get("path", "")).strip():
        raise ValueError(f"databases.{name}.path is required")
    return str(Path(config["databases"][name]["path"]).expanduser().resolve())


def database_ready(name):
    return ROOT + "/00_databases/" + name + ".ready.json"


def checkm2_database_file():
    return database_dir("checkm2") + "/uniref100.KO.1.dmnd"


def bakta_setting(key, default=None):
    """Optional Bakta keys; mode and type are only needed for downloads."""
    return config["databases"].get("bakta", {}).get(key, default)


def bakta_mode():
    mode = bakta_setting("mode", "download")
    if mode not in ("download", "existing"):
        raise ValueError("databases.bakta.mode must be download or existing")
    return mode


def bakta_type():
    db_type = bakta_setting("type", "light")
    if db_type not in BAKTA_ARCHIVES:
        raise ValueError("databases.bakta.type must be light or full")
    return db_type


def bakta_url():
    """Pinned archive URL; required only when downloading."""
    if bakta_mode() != "download":
        return ""
    archive = BAKTA_ARCHIVES[bakta_type()]
    url = str(bakta_setting("url", "")).strip()
    if not url.startswith("https://") or not url.endswith("/" + archive):
        raise ValueError(f"databases.bakta.url must be an HTTPS URL ending in /{archive}")
    target = Path(database_dir("bakta"))
    if target.name != archive[: -len(".tar.xz")]:
        raise ValueError(f"databases.bakta.path must end in {archive[:-len('.tar.xz')]}")
    return url


def bakta_archive():
    return str(Path(database_dir("bakta")).parent / ".downloads" / BAKTA_ARCHIVES[bakta_type()])


rule prepare_databases:
    input:
        [database_ready(name) for name in DATABASE_NAMES]
    # Download/install needs internet access, which compute nodes may lack.
    localrule: True


rule prepare_database:
    output:
        ROOT + "/00_databases/{database}.ready.json"
    wildcard_constraints:
        database="gtdbtk|checkm|checkm2"
    localrule: True
    params:
        script=DATABASE_SCRIPT,
        spec=lambda wc: database_spec(wc.database)
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


if bakta_mode() == "download":
    rule prepare_bakta:
        output:
            database_ready("bakta")
        localrule: True
        params:
            spec=lambda wc: database_spec("bakta"),
            script=DATABASE_SCRIPT,
            database=lambda wc: database_dir("bakta"),
            parent=lambda wc: str(Path(database_dir("bakta")).parent),
            archive=lambda wc: bakta_archive(),
            url=lambda wc: bakta_url(),
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
            mkdir -p "$(dirname {log:q})" {params.parent:q} "$(dirname {params.archive:q})"
            if [[ ! -s {params.database:q}/version.json ]]; then
                {{
                    wget -c -O {params.archive:q} {params.url:q}
                    bakta_db install -i {params.archive:q} --output {params.parent:q}
                    # bakta_db install also updates AMRFinderPlus; keep the documented manual step.
                    amrfinder_update --force_update --database {params.database:q}/amrfinderplus-db/
                }} >> {log:q} 2>&1
            fi
            {PYTHON:q} {params.script:q} --name bakta --spec {params.spec:q} \
                --marker {output:q} --validate-only >> {log:q} 2>&1
            """
else:
    # The database directory is provided by the user: validate it locally as part
    # of prepare_databases instead of submitting a cluster job or creating an env.
    rule prepare_bakta:
        output:
            database_ready("bakta")
        localrule: True
        params:
            spec=lambda wc: database_spec("bakta"),
            script=DATABASE_SCRIPT,
        log:
            ROOT + "/logs/databases/bakta.log"
        shell:
            r"""
            mkdir -p "$(dirname {log:q})"
            {PYTHON:q} {params.script:q} --name bakta --spec {params.spec:q} \
                --marker {output:q} --validate-only > {log:q} 2>&1
            """
