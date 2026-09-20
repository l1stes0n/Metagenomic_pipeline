rule read_qc:
    input:
        r1=lambda wc: SAMPLE_DATA[wc.sample]["r1"],
        r2=lambda wc: SAMPLE_DATA[wc.sample]["r2"]
    output:
        qc=directory(QC)
    threads: setting("read_qc", "threads")
    resources:
        partition=setting("read_qc", "partition"),
        runtime=setting("read_qc", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        quality=config["qc"]["qualified_quality_phred"],
        length=config["qc"]["length_required"]
    conda: ENVS["fastp"]
    log: "logs/read_qc/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        {{
            mkdir -p {output.qc:q}
            fastp --in1 {input.r1:q} --in2 {input.r2:q} \
                --out1 {output.qc:q}/final_pure_reads_1.fastq \
                --out2 {output.qc:q}/final_pure_reads_2.fastq \
                --thread {threads} --detect_adapter_for_pe \
                --qualified_quality_phred {params.quality} --length_required {params.length} \
                --html {output.qc:q}/fastp.html --json {output.qc:q}/fastp.json
            require_nonempty {output.qc:q}/final_pure_reads_1.fastq {output.qc:q}/final_pure_reads_2.fastq
        }} > {log:q} 2>&1
        """


rule assembly:
    input:
        qc=rules.read_qc.output.qc
    output:
        assembly=directory(ASSEMBLY)
    threads: setting("assembly", "threads")
    resources:
        partition=setting("assembly", "partition"),
        runtime=setting("assembly", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        memory_gb=config["assembly"]["memory_gb"],
        kmers=config["assembly"]["kmers"]
    conda: ENVS["spades"]
    log: "logs/assembly/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        {{
            metaspades.py -1 {input.qc:q}/final_pure_reads_1.fastq \
                -2 {input.qc:q}/final_pure_reads_2.fastq -t {threads} \
                -m {params.memory_gb} -k {params.kmers:q} --only-assembler \
                -o {output.assembly:q}
            require_nonempty {output.assembly:q}/scaffolds.fasta
        }} > {log:q} 2>&1
        """


rule index:
    input:
        assembly=rules.assembly.output.assembly
    output:
        l2b=INDEX + ".l2b",
        mbw=INDEX + ".mbw"
    threads: setting("index", "threads")
    resources:
        partition=setting("index", "partition"),
        runtime=setting("index", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        prefix=INDEX
    conda: ENVS["minibwa"]
    log: "logs/index/{sample}.log"
    shell:
        r"""
        limit_threads {threads}
        minibwa index -t {threads} {input.assembly:q}/scaffolds.fasta {params.prefix:q} > {log:q} 2>&1
        require_nonempty {output.l2b:q} {output.mbw:q}
        """


rule mapping:
    input:
        l2b=rules.index.output.l2b,
        mbw=rules.index.output.mbw,
        qc=rules.read_qc.output.qc
    output:
        sam=temp(ROOT + "/03_mapping/{sample}/assembly.sam")
    threads: setting("mapping", "threads")
    resources:
        partition=setting("mapping", "partition"),
        runtime=setting("mapping", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        prefix=INDEX,
        # minibwa adds up to two I/O threads when workers > 1.
        workers=lambda wc, threads: max(1, threads - 2)
    conda: ENVS["minibwa"]
    log: "logs/mapping/{sample}.log"
    shell:
        r"""
        limit_threads 1
        minibwa map -t {params.workers} {params.prefix:q} \
            {input.qc:q}/final_pure_reads_1.fastq {input.qc:q}/final_pure_reads_2.fastq \
            > {output.sam:q} 2> {log:q}
        require_nonempty {output.sam:q}
        """


rule sort_bam:
    input:
        sam=rules.mapping.output.sam
    output:
        bam=BAM,
        bai=BAM + ".bai"
    threads: setting("sort_bam", "threads")
    resources:
        partition=setting("sort_bam", "partition"),
        runtime=setting("sort_bam", "runtime"),
        slurm_account=config["slurm_account"]
    params:
        extra_threads=lambda wc, threads: max(0, threads - 1)
    conda: ENVS["minibwa"]
    log: "logs/sort_bam/{sample}.log"
    shell:
        r"""
        limit_threads 1
        {{
            samtools sort -@ {params.extra_threads} -T {output.bam:q}.sorttmp \
                -O BAM -o {output.bam:q} {input.sam:q}
            samtools index -@ {params.extra_threads} {output.bam:q} {output.bai:q}
            samtools quickcheck -v {output.bam:q}
        }} > {log:q} 2>&1
        """
