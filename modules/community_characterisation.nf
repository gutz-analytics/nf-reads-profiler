// ------------------------------------------------------------------------------
//  COMMUNITY CHARACTERISATION
// ------------------------------------------------------------------------------
/**
  Community Characterisation - STEP 1. Performs taxonomic binning and estimates the
  microbial relative abundances using MetaPhlAn and its databases of clade-specific markers.
*/


// Defines channels for bowtie2_metaphlan_databases file
// Channel.fromPath( params.metaphlan_databases, type: 'dir', checkIfExists: true ).set { bowtie2_metaphlan_databases }

process profile_taxa {

  tag "$name"

  //Enable multicontainer settings
  container params.docker_container_metaphlan

  publishDir "${params.outdir}/${params.project}/${run}/taxa", mode: 'copy', pattern: "*.{biom,tsv,txt,bz2}"

  // Clean up bowtie2 intermediate files after completion (can be 1-5GB per sample)
  afterScript 'rm -f *.sam *.sam.bz2 *.bowtie2.* *.bt2* 2>/dev/null || true; rm -rf metaphlan_bowtie2_* 2>/dev/null || true'

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_metaphlan.biom"), emit: to_profile_function_bugs
  tuple val(meta), path("*_metaphlan_profile.tsv"), optional: true, emit: metaphlan_tsv
  // tuple val(meta), path("*_profile_taxa_mqc.yaml"), emit: profile_taxa_log


  when:
  !params.rna

  script:
  name = task.ext.name ?: "${meta.id}"
  run = task.ext.run ?: "${meta.run}"
  // When reuse_metaphlan_profile is enabled, produce a TSV profile that HUMAnN can
  // consume via --taxonomic-profile. We run MetaPhlAn once as TSV (with rel_ab_w_read_stats
  // which HUMAnN requires) then convert to biom — avoiding a double MetaPhlAn run.
  produce_tsv = params.reuse_metaphlan_profile ? 'true' : 'false'
  """
  echo ${params.metaphlan_db}

  if [ "${produce_tsv}" = "true" ]; then
    # Single MetaPhlAn run producing TSV (for HUMAnN) then convert to biom
    metaphlan \\
      --input_type fastq \\
      --tmp_dir . \\
      --index ${params.metaphlan_index} \\
      --db_dir ${params.metaphlan_db} \\
      --bt2_ps ${params.bt2options} \\
      --sample_id ${name} \\
      -t rel_ab_w_read_stats \\
      --nproc ${task.cpus} \\
      --no_map \\
      --output_file ${name}_metaphlan_profile.tsv \\
      $reads

    # Convert TSV to biom for downstream combine_metaphlan_tables
    biom convert \\
      --input-fp ${name}_metaphlan_profile.tsv \\
      --output-fp ${name}_metaphlan.biom \\
      --table-type 'Taxon table' \\
      --to-hdf5 \\
      --process-obs-metadata taxonomy
  else
    # Default: biom output only (no TSV needed)
    metaphlan \\
      --input_type fastq \\
      --tmp_dir . \\
      --index ${params.metaphlan_index} \\
      --db_dir ${params.metaphlan_db} \\
      --bt2_ps ${params.bt2options} \\
      --sample_id ${name} \\
      --biom_format_output \\
      --nproc ${task.cpus} \\
      --no_map \\
      --output_file ${name}_metaphlan.biom \\
      $reads
  fi
  """
}


/**
  Community Characterisation - STEP 2. Performs the functional annotation using HUMAnN.
*/

// Defines channels for bowtie2_metaphlan_databases file
// Channel.fromPath( params.chocophlan, type: 'dir', checkIfExists: true ).set { chocophlan_databases }
// Channel.fromPath( params.uniref, type: 'dir', checkIfExists: true ).set { uniref_databases }

process profile_function {

  tag "$name"

  //Enable multicontainer settings
  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/function" }, mode: 'copy', pattern: "*.{tsv,log}"

  // Clean up HUMAnN temp files after completion (can be 10-50GB per sample)
  // HUMAnN4 creates *_humann_temp/ dirs with bowtie2 indexes, DIAMOND alignments,
  // ChocoPhlAn database subsets, SAM files, and M8 alignment files.
  // When medi_unmapped_only is enabled, we preserve *_unaligned.fa before cleanup.
  afterScript 'rm -rf *_humann_temp* 2>/dev/null || true; rm -f *.sam *.m8 *.aln 2>/dev/null || true'

  input:
  tuple val(meta), path(reads), path(tax_profile)

  output:
  tuple val(meta), path("*_0.log"), emit: profile_function_log_main
  tuple val(meta), path("*_1_metaphlan_profile.tsv"), emit: profile_function_metaphlan
  tuple val(meta), path("*_2_genefamilies.tsv"), emit: profile_function_gf
  tuple val(meta), path("*_3_reactions.tsv"), emit: profile_function_reactions
  tuple val(meta), path("*_4_pathabundance.tsv"), emit: profile_function_pa
  tuple val(meta), path("*_profile_functions_mqc.yaml"), emit: profile_function_log
  tuple val(meta), path("*_unaligned.fastq.gz"), optional: true, emit: unaligned_reads

  when:
  params.annotation

  script:
  name = task.ext.name ?: "${meta.id}"
  run = task.ext.run ?: "${meta.run}"
  bypass_flag = params.bypass_translated_search ? '--bypass-translated-search' : ''
  preserve_unaligned = params.medi_unmapped_only && params.enable_medi ? 'true' : 'false'
  // When a pre-computed taxonomic profile is provided, HUMAnN skips its internal MetaPhlAn
  // run entirely (~20min savings per sample). The profile must be in MetaPhlAn TSV format.
  tax_profile_flag = (tax_profile.name != 'NO_TAXONOMY_PROFILE') ? "--taxonomic-profile ${tax_profile}" : ''
  metaphlan_opts = (tax_profile.name != 'NO_TAXONOMY_PROFILE') ? '' : "--metaphlan-options \"-t rel_ab_w_read_stats --index ${params.humann_metaphlan_index} --bowtie2db ${params.humann_metaphlan_db} --bt2_ps ${params.bt2options}\""
  """
  # HUMAnN 4 functional profiling
  # When tax_profile is provided, HUMAnN skips its internal MetaPhlAn (~20min saved)
  humann \\
    --input $reads \\
    --output . \\
    ${params.humann_params} \\
    ${bypass_flag} \\
    ${tax_profile_flag} \\
    --output-basename ${name} \\
    --nucleotide-database ${params.chocophlan} \\
    --remove-column-description-output \\
    --protein-database ${params.uniref} \\
    --utility-database ${params.utility_mapping} \\
    ${metaphlan_opts} \\
    --pathways metacyc \\
    --threads ${task.cpus} \\
    --memory-use minimum

  # Preserve unaligned reads for MEDI if medi_unmapped_only is enabled.
  # HUMAnN temp dir contains *_diamond_unaligned.fa (reads not in ChocoPhlAn OR UniRef)
  # and *_bowtie2_unaligned.fa (reads not in ChocoPhlAn only).
  # We use diamond_unaligned when available (fully unmapped), falling back to bowtie2_unaligned
  # (for bypass_translated_search mode where Diamond doesn't run).
  if [ "${preserve_unaligned}" = "true" ]; then
    unaligned_fa=""
    if [ -f ${name}_humann_temp/${name}_diamond_unaligned.fa ]; then
      unaligned_fa="${name}_humann_temp/${name}_diamond_unaligned.fa"
    elif [ -f ${name}_humann_temp/${name}_bowtie2_unaligned.fa ]; then
      unaligned_fa="${name}_humann_temp/${name}_bowtie2_unaligned.fa"
    fi

    if [ -n "\$unaligned_fa" ] && [ -s "\$unaligned_fa" ]; then
      # Convert FASTA to FASTQ (Kraken2 accepts both, but gzipped FASTQ is consistent
      # with the rest of the pipeline). Assign quality score of 'I' (Q40) since these
      # reads already passed QC in clean_reads.
      awk 'BEGIN{OFS="\\n"} /^>/{name=substr(\$0,2); next} {print "@"name, \$0, "+", gensub(/./, "I", "g", \$0)}' \\
        "\$unaligned_fa" | gzip -1 > ${name}_unaligned.fastq.gz
      echo "Preserved \$(zcat ${name}_unaligned.fastq.gz | wc -l | awk '{print \$1/4}') unaligned reads for MEDI"
    else
      echo "No unaligned reads found in HUMAnN temp directory (sample may have 0% unaligned)"
    fi
  fi

  # MultiQC doesn't have a module for humann yet. As a consequence, I
  # had to create a YAML file with all the info I need via a bash script
  bash scrape_profile_functions.sh ${name} ${name}_0.log > ${name}_profile_functions_mqc.yaml
  """
}


process combine_humann_tables {
  tag "$run"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/combined_tables" }, mode: 'copy', pattern: "*.{tsv,log}"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path('*_combined.tsv')

  when:
  params.annotation

  script:

  run = task.ext.run ?: "${meta.run}"
  type = task.ext.type ?: "${meta.type}"
  """
  echo "Combining ${type} tables..."
  echo "Files to combine:"
  ls -la *${type}*
  
  # Check for empty or malformed files
  for file in *${type}*; do
    if [ -s "\$file" ]; then
      echo "File \$file size: \$(wc -l < "\$file") lines"
      echo "First few lines of \$file:"
      head -n 5 "\$file"
    else
      echo "Warning: \$file is empty or does not exist"
    fi
  done
  
  # Try to combine tables with verbose output
  humann_join_tables \\
    -i ./ \\
    -o ${run}_${type}_combined.tsv \\
    --file_name ${type} \\
    --verbose
  """
}

process combine_metaphlan_tables {
  tag "$run"

  container params.docker_container_metaphlan

  publishDir {"${params.outdir}/${params.project}/${run}/combined_tables" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/metaphlan" }, mode: 'copy', pattern: "*.biom"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path('*.biom'), emit: combined_biom

  script:
  run = task.ext.run ?: "${meta.run}"
  biom_files = table.join(' ')
  """
  python3 << 'EOF'
import biom
import sys

# Get biom files from command line arguments
biom_files = "${biom_files}".split()

if len(biom_files) == 1:
    # Only one file, just copy it
    table = biom.load_table(biom_files[0])
else:
    # Load all tables
    tables = [biom.load_table(f) for f in biom_files]
    
    # Merge tables
    table = tables[0]
    for t in tables[1:]:
        table = table.merge(t)

# Write merged table
with biom.util.biom_open("${run}_metaphlan_combined.biom", 'w') as f:
    table.to_hdf5(f, "merged metaphlan table")
EOF
  """
}

process combine_humann_taxonomy_tables {
  tag "$run"

  container params.docker_container_metaphlan

  publishDir {"${params.outdir}/${params.project}/${run}/combined_tables" }, mode: 'copy', pattern: "*.tsv"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path('*.tsv'), emit: combined_tsv

  script:
  run = task.ext.run ?: "${meta.run}"
  table_files = table.join(' ')
  """
  echo "Combining HUMAnN taxonomy tables..."
  echo "Files to combine:"
  ls -la *.tsv
  
  # Use MetaPhlAn's merge script to combine the tables
  merge_metaphlan_tables.py \\
    ${table_files} \\
    -o ${run}_humann_taxonomy_combined.tsv \\
    --overwrite
  """
}


process convert_tables_to_biom {
  tag "${run}_${type}"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/combined_tables" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/genefamilies" }, mode: 'copy', pattern: "*_genefamilies*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/pathabundance" }, mode: 'copy', pattern: "*_pathabundance*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/reactions" }, mode: 'copy', pattern: "*_reactions*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/humann_taxonomy" }, mode: 'copy', pattern: "*_humann_taxonomy.biom"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path("*.biom"), emit: biom_files

  when:
  params.annotation

  script:
  run = task.ext.run ?: "${meta.run}"
  type = task.ext.type ?: "${meta.type}"
  stratification = task.ext.stratification ?: "${meta.stratification}"
  table_type = (type == 'humann_taxonomy') ? 'Taxon table' : 'Function table'
  output_name = (stratification && stratification != 'combined' && stratification != 'null') ? "${run}_${type}_${stratification}.biom" : "${run}_${type}.biom"
  """
  echo "Converting ${type} table to biom format (${stratification})"
  biom convert \\
    --input-fp ${table} \\
    --output-fp ${output_name} \\
    --table-type '${table_type}' \\
    --to-hdf5
  """
}

process split_stratified_tables {
  tag "${run}_${type}"

  container params.docker_container_humann4

  input:
  tuple val(meta), path(tsv_table)

  output:
  tuple val(meta), path("*_stratified.tsv"), emit: stratified_tables
  tuple val(meta), path("*_unstratified.tsv"), emit: unstratified_tables

  when:
  params.annotation

  script:
  run = task.ext.run ?: "${meta.run}"
  type = task.ext.type ?: "${meta.type}"
  """
  echo "Splitting stratified table: ${tsv_table} (type: ${type})"
  
  # Split the table into stratified and unstratified versions
  humann_split_stratified_table \\
    -i ${tsv_table} \\
    -o .
    
  # List what was created
  echo "Split files created:"
  ls -la *.tsv
  """
}

process regroup_genefamilies {
  tag "${run}_${type}"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/function/regrouped" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/regrouped" }, mode: 'copy', pattern: "*.biom"

  input:
  tuple val(meta), path(genefamilies_biom)

  output:
  tuple val(meta), path("*.biom"), emit: regrouped_bioms

  when:
  params.annotation && params.process_humann_tables && meta.type == 'genefamilies'

  script:
  run = task.ext.run ?: "${meta.run}"
  type = task.ext.type ?: "${meta.type}"
  stratification = task.ext.stratification ?: "${meta.stratification}"
  regroups = params.humann_regroups ?: "uniref90_ko,uniref90_rxn"
  """
  echo "Regrouping genefamilies table: ${genefamilies_biom} (${stratification})"
  
  # Process each regroup type using safe_cluster_process.py
  IFS=',' read -r -a groups <<< "${regroups}"
  for group in "\${groups[@]}"; do
    echo "Regrouping to \$group using safe_cluster_process.py"
    
    # Use safe_cluster_process.py for regrouping
    safe_cluster_process.py \\
      ${genefamilies_biom} \\
      "humann_regroup_table -i {input} -g \$group -o output_\${group}.biom" \\
      --max-samples ${params.split_size ?: 100} \\
      --num-threads ${task.cpus} \\
      --final-output-dir . \\
      --command-output-location . \\
      --output-regex-patterns ".*\\.biom\$" \\
      --output-group-names "\${group}" \\
      --output-prefix ${run}_${type}_${stratification}
      
    # The output will be named ${run}_${type}_${stratification}_\${group}.biom
    mv ${run}_${type}_${stratification}_\${group}.biom ${run}_${type}_${stratification}.\${group}.biom
  done

  echo "Regrouping complete"
  """
}

