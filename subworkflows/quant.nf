#!/usr/bin/env nextflow

/* Helper functions */

// Helper to calculate the required RAM for the Kraken2 database
def estimate_db_size(hash) {
    def db_size = null

    // Calculate db memory requirement
    if (params.dbmem) {
        db_size = MemoryUnit.of("${params.dbmem} GB")
    } else {
        db_size = MemoryUnit.of(file(hash).size()) + 6.GB
        log.info("Based on the hash size I am reserving ${db_size.toGiga()}GB of memory for Kraken2.")
    }

    return db_size
}


/********************/

/* Workflow definition starts here */

workflow MEDI_QUANT {
    take:
        reads               // tuple val(meta), path(reads)
        db_path
        foods_file
        food_contents_file
        
    main:
        Channel
            .fromList(["D", "G", "S"])
            .set{levels}

        // quantify taxa abundances
        batched = reads    // buffer the samples into batches
            .collate(params.batchsize ?: 400)
            .map{batch -> 
                // Extract meta from first sample in batch and collect all reads
                def meta = batch[0][0]  // meta from first sample
                def reads_files = batch.collect{it[1]}.flatten()
                [meta, reads_files]
            }

        // run Kraken2 per batch
        kraken(batched, db_path)

        // filter Kraken2 results and generate reports
        kraken_k2_channel = kraken.out
            .flatMap{meta, k2_files, tsv_files -> 
                k2_files.collect{k2_file -> [meta, k2_file]}
            }
            
        architeuthis_filter(kraken_k2_channel, db_path)

        kraken_report(architeuthis_filter.out, db_path)

        count_taxa(kraken_report.out.combine(levels), db_path)

        count_taxa.out.map{meta, lev, file -> tuple(meta, lev, file)}
            .groupTuple(by: [0, 1])  // group by meta and level
            .set{merge_groups}
        merge_taxonomy(merge_groups)

        if (params.mapping ?: false) {
            // Get individual mappings
            summarize_mappings(architeuthis_filter.out, db_path)
            summarize_mappings.out.map{meta, file -> file}.collect() | merge_mappings
        }

        // Add taxon lineages
        add_lineage(merge_taxonomy.out, db_path)

        // Quantify foods
        quantify(add_lineage.out.map{meta, file -> file}.collect(), foods_file, food_contents_file)

        // quality overview
        multiqc(merge_taxonomy.out.map{meta, lev, file -> file}.collect())
        
    emit:
        food_abundance = quantify.out.map{it[0]}
        food_content = quantify.out.map{it[1]}
        taxonomy_counts = add_lineage.out
        qc_report = multiqc.out
        mappings = params.mapping ? merge_mappings.out : Channel.empty()
}

/* Process definitions */


process kraken {
    tag "$run"
    label 'highmem'
    scratch false
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2"

    input:
    tuple val(meta), path(reads)
    path(db_path)

    output:
    tuple val(meta), path("*.k2"), path("*.tsv")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    #!/usr/bin/env python

    import sys
    import os
    from subprocess import run

    base_args = [
        "kraken2", "--db", "${db_path}",
        "--confidence", "${params.confidence ?: 0.3}",
        "--threads", "${task.cpus}", "--gzip-compressed"
    ]

    reads = "${reads}".split()

    # Treat all reads as single-end (merged/cleaned reads)
    for read in reads:
        idx = read.split("_cleaned")[0] if "_cleaned" in read else read.split(".")[0]
        args = base_args + [
            "--output", f"{idx}.k2",
            "--report", f"{idx}.tsv",
            "--memory-mapping", read
        ]
        res = run(args)
        if res.returncode != 0:
            if os.path.exists(f"{idx}.k2"):
                os.remove(f"{idx}.k2")
            sys.exit(res.returncode)
    """
}

process architeuthis_filter {
    tag "$name"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2", overwrite: true

    input:
    tuple val(meta), path(k2)
    path(db_path)

    output:
    tuple val(meta), path("${name}_filtered.k2")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis mapping filter ${k2} \
        --data-dir ${db_path}/taxonomy \
        --min-consistency ${params.consistency ?: 0.95} --max-entropy ${params.entropy ?: 0.1} \
        --max-multiplicity ${params.multiplicity ?: 4} \
        --out ${name}_filtered.k2
    """
}

process kraken_report {
    tag "$name"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2", overwrite: true

    input:
    tuple val(meta), path(k2)
    path(db_path)

    output:
    tuple val(meta), path("*.tsv")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    kraken2-report ${db_path}/taxo.k2d ${k2} ${name}.tsv
    """
}

process summarize_mappings {
    tag "$name"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi/architeuthis"

    input:
    tuple val(meta), path(k2)
    path(db_path)

    output:
    tuple val(meta), path("${name}_mapping.csv")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis mapping summary ${k2} --data-dir ${db_path}/taxonomy --out ${name}_mapping.csv
    """
}

process merge_mappings {
    tag "merge"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(meta), path(mappings)

    output:
    path("mappings.csv")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis merge ${mappings} --out mappings.csv
    """
}

process count_taxa {
    tag "${name}_${lev}"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi/bracken", overwrite: true

    input:
    tuple val(meta), path(report), val(lev)
    path(db_path)

    output:
    tuple val(meta), val(lev), path("${lev}/${lev}_${name}.b2")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    mkdir ${lev} && \
        fixk2report.R ${report} ${lev}/${report} && \
        bracken -d ${db_path} -i ${lev}/${report} \
        -l ${lev} -o ${lev}/${lev}_${name}.b2 -r ${params.read_length ?: 150} \
        -t ${params.threshold ?: 10} -w ${lev}/${name}_bracken.tsv
    """
}

process quantify {
    tag "quantify"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(meta), path(files)
    path(foods_file)
    path(food_contents_file)

    output:
    tuple path("food_abundance.csv"), path("food_content.csv")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    quantify.R ${foods_file} ${food_contents_file} ${files}
    """
}

process merge_taxonomy {
    tag "${run}_${lev}"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi/merged", mode: "copy", overwrite: true

    input:
    tuple val(meta), val(lev), path(reports)

    output:
    tuple val(meta), val(lev), path("${lev}_merged.csv")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis merge ${reports} --out ${lev}_merged.csv
    """
}

process add_lineage {
    tag "${run}_${lev}"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(meta), val(lev), path(merged)
    path(db_path)

    output:
    tuple val(meta), path("${lev}_counts.csv")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis lineage ${merged} --data-dir ${db_path}/taxonomy --out ${lev}_counts.csv
    """
}


process multiqc {
    tag "multiqc"
    label 'low'
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(meta), path(report)

    output:
    path("multiqc_report.html")

    script:
    run = task.ext.run ?: "${meta.run}"
    """
    multiqc ${params.outdir}/${params.project}/*/medi/kraken2
    """
}
