#!/usr/bin/env nextflow

/* Helper functions */

// Helper to calculate the required RAM for the Kraken2 database
def estimate_db_size() {
    def db_size = null

    // Calculate db memory requirement
    if (params.dbmem) {
        db_size = MemoryUnit.of("${params.dbmem} GB")
    } else {
        def hash_file = file("${params.medi_db_path}/hash.k2d")
        if (hash_file.exists()) {
            db_size = MemoryUnit.of(hash_file.size()) + 6.GB
            log.info("Based on the hash size I am reserving ${db_size.toGiga()}GB of memory for Kraken2.")
        } else {
            db_size = MemoryUnit.of("32 GB")  // Default fallback
            log.info("Could not find hash file, using default 32GB memory for Kraken2.")
        }
    }

    return db_size
}

// Helper to get ramdisk size in string format for startTask (e.g., "490G")
def get_ramdisk_size_string() {
    def db_size = estimate_db_size()
    return "${db_size.toGiga()}G"
}


/********************/

/* Workflow definition starts here */

workflow MEDI_QUANT {
    take:
        studies_with_samples // channel of [study_id, [samples]] where samples are [[meta, reads], ...]
        foods_file_path      // String path to foods file on mounted filesystem
        food_contents_file_path  // String path to food contents file on mounted filesystem
        
    main:
        channel
            .fromList(["D", "G", "S"])
            .set{levels}

        // Flatten studies back to individual samples for processing.
        // Input is HUMAnN fully-unaligned reads: already QC'd, single-end gzipped FASTA.
        reads = studies_with_samples.flatMap{_study_id, samples ->
            samples.collect{meta, reads -> [meta, reads]}
        }

        // Run Kraken2 directly — no fastp preprocessing needed (reads are already QC'd)
        kraken(reads)

        // Extract k2 files from kraken output (metadata preserved)
        kraken_k2_channel = kraken.out.map { meta, k2_file, _tsv_file -> [meta, k2_file] }

        // Debug: Show individual k2 files with preserved metadata
        // kraken_k2_channel.view { meta, k2_file -> "K2 File: Study=${meta.run}, Sample=${meta.id}, File=${k2_file.name}" }

        architeuthis_filter(kraken_k2_channel)

        kraken_report(architeuthis_filter.out)

        count_taxa(kraken_report.out.combine(levels))

        // Group by study and taxonomic level for merging (multiple studies possible)
        count_taxa.out
            .map{meta, lev, file -> 
                def group_key = [study: meta.run, level: lev]
                [group_key, file]
            }
            .groupTuple()
            .set{merge_groups}
        
        // Debug: Show merge groups
        // merge_groups.view { group_key, files -> "Merge Group: Study=${group_key.study}, Level=${group_key.level}, Files=${files.size()}" }
        
        merge_taxonomy(merge_groups)

        if (params.mapping ?: false) {
            // Get individual mappings
            summarize_mappings(architeuthis_filter.out)
            summarize_mappings.out.map{_meta, file -> file}.collect() | merge_mappings
        }

        // Add taxon lineages
        add_lineage(merge_taxonomy.out)

        // Quantify foods - collect taxonomy files by study
        add_lineage.out
            .map{group_key, file -> [group_key.study, file]}  // Group by study
            .groupTuple()
            .set{taxonomy_by_study}
            
        quantify(taxonomy_by_study, foods_file_path, food_contents_file_path)

        // Convert MEDI CSV outputs to BIOM format
        convert_medi_to_biom(quantify.out)

        // quality overview - collect filtered kraken reports by study for multiqc
        kraken_report.out
            .map{meta, file -> [meta.run, file]}  // Group by study
            .groupTuple()
            .set{kraken_reports_by_study}
            
        multiqc(kraken_reports_by_study)
        
    emit:
        food_abundance = quantify.out.map{row -> row[1]}
        food_content = quantify.out.map{row -> row[2]}
        taxonomy_counts = add_lineage.out
        qc_report = multiqc.out
        mappings = params.mapping ? merge_mappings.out : channel.empty()
}

/* Process definitions */

process kraken {
    tag "$name"
    label 'kraken'
    scratch false
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi/kraken2"}, mode: 'copy'

    // containerOptions '--volume /tmp/ramdisk:/tmp/ramdisk'
    cpus 8

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta), path("*.k2"), path("*.tsv")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    #!/usr/bin/env python

    import sys
    import os
    import shutil
    from subprocess import run, check_call, CalledProcessError
    import time

    db_source = "${params.medi_db_path}"
    # ramdisk_mount = "/tmp/ramdisk"  # Use the ramdisk created by startTask
    ramdisk_mount = "/mnt/scratch/ssddbs/medi_db/" # Use nvme scratch
    sample_name = "${name}"
    
    print(f"Processing sample: {sample_name}")
    print(f"Source database: {db_source}")
    print(f"Available memory: ${task.memory}")
    print(f"Using ${task.cpus} threads")
    
    # Check if ramdisk created by startTask is available
    use_ramdisk = False
    db_path = db_source  # Default to source path

    # Process reads with kraken2
    base_args = [
        "kraken2", "--db", db_path,
        "--confidence", "${params.confidence ?: 0.3}",
        "--threads", "${task.cpus}",
        "--output", f"{sample_name}.k2",
        "--report", f"{sample_name}.tsv"
    ]
    
    # Add memory-mapping flag if using ramdisk (database already in memory)
    # if use_ramdisk:
    # Add it anyway!
    base_args.append("--memory-mapping")
    print("Using --memory-mapping flag (database in ramdisk)")

    reads = "${reads}".split()
    
    print(f"Processing {len(reads)} read files for sample {sample_name}")

    # Determine if paired-end based on number of files
    if len(reads) == 2:
        reads.sort()  # Ensure R1, R2 order
        args = base_args + ["--paired"] + reads
        print(f"Processing paired-end sample {sample_name}: {reads}")
    else:
        args = base_args + reads
        print(f"Processing single-end sample {sample_name}: {reads}")
    
    start_time = time.time()
    res = run(args)
    end_time = time.time()
    
    print(f"Completed {sample_name} in {end_time - start_time:.1f} seconds")
    
    if res.returncode != 0:
        print(f"Error processing {sample_name}")
        if os.path.exists(f"{sample_name}.k2"):
            os.remove(f"{sample_name}.k2")
        sys.exit(res.returncode)
    
    print("Kraken2 processing completed successfully")
    """
}

process architeuthis_filter {
    tag "$name"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi/kraken2"}, overwrite: true, mode: 'copy'

    input:
    tuple val(meta), path(k2)

    output:
    tuple val(meta), path("${name}_filtered.k2")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis mapping filter ${k2} \
        --data-dir ${params.medi_db_path}/taxonomy \
        --min-consistency ${params.consistency ?: 0.95} --max-entropy ${params.entropy ?: 0.1} \
        --max-multiplicity ${params.multiplicity ?: 4} \
        --out ${name}_filtered.k2
    """
}

process kraken_report {
    tag "$name"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi/kraken2"}, overwrite: true, mode: 'copy'

    input:
    tuple val(meta), path(k2)

    output:
    tuple val(meta), path("*.tsv")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    kraken2-report ${params.medi_db_path}/taxo.k2d ${k2} ${name}.tsv
    """
}

process summarize_mappings {
    tag "$name"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi/architeuthis"}, overwrite: true, mode: 'copy'

    input:
    tuple val(meta), path(k2)

    output:
    tuple val(meta), path("${name}_mapping.csv")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    architeuthis mapping summary ${k2} --data-dir ${params.medi_db_path}/taxonomy --out ${name}_mapping.csv
    """
}

process merge_mappings {
    tag "merge"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi"}, mode: "copy", overwrite: true

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
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${task.ext.run ?: meta.run}/medi/bracken"}, overwrite: true, mode: 'copy'

    input:
    tuple val(meta), path(report), val(lev)

    output:
    tuple val(meta), val(lev), path("${lev}/${lev}_${name}.b2")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    """
    mkdir ${lev} && \
        fixk2report.R ${report} ${lev}/${report} && \
        bracken -d ${params.medi_db_path} -i ${lev}/${report} \
        -l ${lev} -o ${lev}/${lev}_${name}.b2 -r ${params.read_length ?: 150} \
        -t ${params.threshold ?: 10} -w ${lev}/${name}_bracken.tsv
    """
}

process quantify {
    tag "quantify"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${run}/medi"}, mode: "copy", overwrite: true

    input:
    tuple val(run), path(files)
    val(foods_file_path)
    val(food_contents_file_path)

    output:
    tuple val(run), path("food_abundance.csv"), path("food_content.csv")

    script:
    """
    quantify.R ${foods_file_path} ${food_contents_file_path} ${files}
    """
}

process merge_taxonomy {
    tag "${group_key.study}_${group_key.level}"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${group_key.study}/medi/merged"}, mode: "copy", overwrite: true

    input:
    tuple val(group_key), path(reports)

    output:
    tuple val(group_key), path("${group_key.level}_merged.csv")

    script:
    """
    architeuthis merge ${reports} --out ${group_key.level}_merged.csv
    """
}

process add_lineage {
    tag "${group_key.study}_${group_key.level}"
    label 'low'
    container params.docker_container_medi
    publishDir {"${params.outdir}/${params.project}/${group_key.study}/medi"}, mode: "copy", overwrite: true

    input:
    tuple val(group_key), path(merged)

    output:
    tuple val(group_key), path("${group_key.level}_counts.csv")

    script:
    """
    architeuthis lineage ${merged} --data-dir ${params.medi_db_path}/taxonomy --out ${group_key.level}_counts.csv
    """
}


process multiqc {
    tag "multiqc"
    label 'low'
    container params.docker_container_multiqc
    publishDir {"${params.outdir}/${params.project}/${run}/medi"}, mode: "copy", overwrite: true

    input:
    tuple val(run), path(reports)

    output:
    path("multiqc_report.html")

    script:
    """
    multiqc . -f
    """
}

process convert_medi_to_biom {
    tag "${run}"
    label 'low'
    container params.docker_container_metaphlan
    publishDir "${params.outdir}/${params.project}/combined_bioms/medi", mode: "copy", overwrite: true

    input:
    tuple val(run), path(food_abundance), path(food_content)

    output:
    tuple val(run), path("*_food_abundance.biom"), path("*_food_content_nutrients.biom"), path("*_food_content_compounds.biom")

    script:
    """
    # Convert food abundance to BIOM
    medi_csv_to_biom.py ${food_abundance} ${run}_food_abundance.biom --type abundance
    
    # Convert food content to BIOM (creates both nutrients and compounds files)
    medi_csv_to_biom.py ${food_content} ${run}_food_content.biom --type content
    """
}
