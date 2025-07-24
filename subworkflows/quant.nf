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
        Channel
            .fromList(["D", "G", "S"])
            .set{levels}

        // Flatten studies back to individual samples for processing
        reads = studies_with_samples.flatMap{study_id, samples -> 
            samples.collect{meta, reads -> [meta, reads]}
        }

        // Debug: Show incoming reads for each study
        reads.view { meta, reads_file -> "MEDI_QUANT received: Study=${meta.run}, Sample=${meta.id}, Files=${reads_file}" }

        // Quality filtering with fastp (handles both single and paired-end reads)
        preprocess(reads)

        // Process each sample individually - no batching needed with ramdisk
        kraken_input = preprocess.out
            .map{meta, reads_files, json, html -> [meta, reads_files]}  // Extract meta and processed reads

        // Debug: Show individual samples going to Kraken2
        kraken_input.view { meta, reads_files -> "MEDI Kraken2 input: Study=${meta.run}, Sample=${meta.id}, Files=${reads_files}" }
        
        // run Kraken2 per sample - maintains clean metadata flow
        kraken(kraken_input)

        // Extract k2 files from kraken output (metadata preserved)
        kraken_k2_channel = kraken.out.map { meta, k2_file, tsv_file -> [meta, k2_file] }

        // Debug: Show individual k2 files with preserved metadata
        kraken_k2_channel.view { meta, k2_file -> "K2 File: Study=${meta.run}, Sample=${meta.id}, File=${k2_file.name}" }

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
        merge_groups.view { group_key, files -> "Merge Group: Study=${group_key.study}, Level=${group_key.level}, Files=${files.size()}" }
        
        merge_taxonomy(merge_groups)

        if (params.mapping ?: false) {
            // Get individual mappings
            summarize_mappings(architeuthis_filter.out)
            summarize_mappings.out.map{meta, file -> file}.collect() | merge_mappings
        }

        // Add taxon lineages
        add_lineage(merge_taxonomy.out)

        // Quantify foods - collect taxonomy files by study
        add_lineage.out
            .map{group_key, file -> [group_key.study, file]}  // Group by study
            .groupTuple()
            .set{taxonomy_by_study}
            
        quantify(taxonomy_by_study, foods_file_path, food_contents_file_path)

        // quality overview - collect filtered kraken reports by study for multiqc
        kraken_report.out
            .map{meta, file -> [meta.run, file]}  // Group by study
            .groupTuple()
            .set{kraken_reports_by_study}
            
        multiqc(kraken_reports_by_study)
        
    emit:
        food_abundance = quantify.out.map{it[0]}
        food_content = quantify.out.map{it[1]}
        taxonomy_counts = add_lineage.out
        qc_report = multiqc.out
        mappings = params.mapping ? merge_mappings.out : Channel.empty()
}

/* Process definitions */

process preprocess {
    tag "$name"
    label 'low'
    container params.docker_container_fastp
    publishDir "${params.outdir}/${params.project}/${run}/medi/preprocessed"

    input:
    tuple val(meta), path(reads)

    output:
    tuple val(meta),
        path("${name}_filtered_R*.fastq.gz"),
        path("${name}_fastp.json"),
        path("${name}.html")

    script:
    name = task.ext.name ?: "${meta.id}"
    run = task.ext.run ?: "${meta.run}"
    if (meta.single_end)
        """
        fastp -i ${reads[0]} -o ${name}_filtered_R1.fastq.gz \
            --json ${name}_fastp.json --html ${name}.html \
            --trim_front1 ${params.trim_front ?: 5} -l ${params.min_length ?: 50} \
            -3 -M ${params.quality_threshold ?: 20} -r -w ${task.cpus}
        """
    else
        """
        fastp -i ${reads[0]} -I ${reads[1]} \
            -o ${name}_filtered_R1.fastq.gz -O ${name}_filtered_R2.fastq.gz \
            --json ${name}_fastp.json --html ${name}.html \
            --trim_front1 ${params.trim_front ?: 5} -l ${params.min_length ?: 50} \
            -3 -M ${params.quality_threshold ?: 20} -r -w ${task.cpus}
        """
}

process kraken {
    tag "$name"
    label 'kraken'
    scratch false
    container params.docker_container_medi
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2"

    containerOptions '--volume /tmp/ramdisk:/tmp/ramdisk'

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
    ramdisk_mount = "/tmp/ramdisk"  # Use the ramdisk created by startTask
    sample_name = "${name}"
    
    print(f"Processing sample: {sample_name}")
    print(f"Source database: {db_source}")
    print(f"Available memory: ${task.memory}")
    print(f"Using ${task.cpus} threads")
    
    # Check if ramdisk created by startTask is available
    use_ramdisk = False
    db_path = db_source  # Default to source path
    
    try:
        # Check if the ramdisk from startTask is available
        if os.path.ismount(ramdisk_mount):
            print(f"Found existing ramdisk at {ramdisk_mount} (created by startTask)")
            
            # Create a subdirectory for this database to avoid conflicts
            db_ramdisk_path = os.path.join(ramdisk_mount, "kraken_db")
            os.makedirs(db_ramdisk_path, exist_ok=True)
            
            # Check if database files are already present in ramdisk
            required_files = ["hash.k2d", "opts.k2d", "taxo.k2d"]
            missing_files = []
            for req_file in required_files:
                if not os.path.exists(os.path.join(db_ramdisk_path, req_file)):
                    missing_files.append(req_file)
            
            if missing_files:
                # Copy missing database files to ramdisk
                print(f"Copying {len(missing_files)} missing database files to ramdisk...")
                copy_start = time.time()
                
                for file_name in missing_files:
                    src_path = os.path.join(db_source, file_name)
                    dst_path = os.path.join(db_ramdisk_path, file_name)
                    
                    print(f"Copying {file_name}...")
                    shutil.copy2(src_path, dst_path)
                
                copy_end = time.time()
                print(f"Database copy completed in {copy_end - copy_start:.1f} seconds")
            else:
                print("Database files already present in ramdisk - skipping copy")
            
            # Verify all database files are now present
            final_missing = []
            for req_file in required_files:
                if not os.path.exists(os.path.join(db_ramdisk_path, req_file)):
                    final_missing.append(req_file)
            
            if final_missing:
                print(f"Warning: Missing required files in ramdisk: {final_missing}")
                raise Exception(f"Incomplete database setup: missing {final_missing}")
            
            use_ramdisk = True
            db_path = db_ramdisk_path
            print("Ramdisk database setup completed successfully")
            
        else:
            print(f"No ramdisk found at {ramdisk_mount}, using direct database access")
            
    except Exception as e:
        print(f"Failed to setup ramdisk: {e}")
        print("Falling back to direct database access")

    # Process reads with kraken2
    base_args = [
        "kraken2", "--db", db_path,
        "--confidence", "${params.confidence ?: 0.3}",
        "--threads", "${task.cpus}", 
        "--gzip-compressed",
        "--output", f"{sample_name}.k2",
        "--report", f"{sample_name}.tsv"
    ]
    
    # Add memory-mapping flag if using ramdisk (database already in memory)
    if use_ramdisk:
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
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2", overwrite: true

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
    publishDir "${params.outdir}/${params.project}/${run}/medi/kraken2", overwrite: true

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
    publishDir "${params.outdir}/${params.project}/${run}/medi/architeuthis"

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
    container params.docker_container_medi
    publishDir "${params.outdir}/${params.project}/${run}/medi/bracken", overwrite: true

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
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(run), path(files)
    val(foods_file_path)
    val(food_contents_file_path)

    output:
    tuple path("food_abundance.csv"), path("food_content.csv")

    script:
    """
    quantify.R ${foods_file_path} ${food_contents_file_path} ${files}
    """
}

process merge_taxonomy {
    tag "${group_key.study}_${group_key.level}"
    label 'low'
    container params.docker_container_medi
    publishDir "${params.outdir}/${params.project}/${group_key.study}/medi/merged", mode: "copy", overwrite: true

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
    publishDir "${params.outdir}/${params.project}/${group_key.study}/medi", mode: "copy", overwrite: true

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
    publishDir "${params.outdir}/${params.project}/${run}/medi", mode: "copy", overwrite: true

    input:
    tuple val(run), path(reports)

    output:
    path("multiqc_report.html")

    script:
    """
    multiqc . -f
    """
}
