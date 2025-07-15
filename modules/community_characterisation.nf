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

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_metaphlan.biom"), emit: to_profile_function_bugs
  // tuple val(meta), path("*_profile_taxa_mqc.yaml"), emit: profile_taxa_log


  when:
  !params.rna

  script:
  name = task.ext.name ?: "${meta.id}"
  run = task.ext.run ?: "${meta.run}"
  """
  echo ${params.metaphlan_db}

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
    $reads \\
    

  # MultiQC doesn't have a module for Metaphlan yet. As a consequence, I
  # had to create a YAML pathwith all the info I need via a bash script
  # bash scrape_profile_taxa_log.sh ${name}_metaphlan_bugs_list.tsv > ${name}_profile_taxa_mqc.yaml
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

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_0.log"), emit: profile_function_log_main
  tuple val(meta), path("*_1_metaphlan_profile.tsv"), emit: profile_function_metaphlan
  tuple val(meta), path("*_2_genefamilies.tsv"), emit: profile_function_gf
  tuple val(meta), path("*_3_reactions.tsv"), emit: profile_function_reactions
  tuple val(meta), path("*_4_pathabundance.tsv"), emit: profile_function_pa
  tuple val(meta), path("*_profile_functions_mqc.yaml"), emit: profile_function_log

  when:
  params.annotation

  script:
  name = task.ext.name ?: "${meta.id}"
  run = task.ext.run ?: "${meta.run}"
  """
  # HUMAnN 4 will run its own MetaPhlAn profiling internally
  humann \\
    --input $reads \\
    --output . \\
    ${params.humann_params} \\
    --output-basename ${name} \\
    --nucleotide-database ${params.chocophlan} \\
    --remove-column-description-output \\
    --protein-database ${params.uniref} \\
    --utility-database ${params.utility_mapping} \\
    --metaphlan-options "-t rel_ab_w_read_stats --index ${params.humann_metaphlan_index} --bowtie2db ${params.humann_metaphlan_db} --bt2_ps ${params.bt2options}" \\
    --pathways metacyc \\
    --threads ${task.cpus} \\
    --memory-use minimum

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

process process_humann_tables {
  tag "$run"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/function/processed" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/genefamilies" }, mode: 'copy', pattern: "*_genefamilies.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/regrouped" }, mode: 'copy', pattern: "*_genefamilies.*.biom"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path("*_genefamilies.biom"), emit: genefamilies_biom
  tuple val(meta), path("*_genefamilies.*.biom"), emit: regrouped_bioms

  when:
  params.annotation && params.process_humann_tables

  script:
  run = task.ext.run ?: "${meta.run}"
  regroups = params.humann_regroups ?: "uniref90_ko,uniref90_rxn"
  """
  # Convert to biom format
  echo "Converting HUMAnN table to biom"
  biom convert \\
    --input-fp ${table} \\
    --output-fp ${run}_genefamilies.biom \\
    --table-type 'Function table' \\
    --to-hdf5

  # Process each regroup type using safe_regroup.py
  IFS=',' read -r -a groups <<< "${regroups}"
  for group in "\${groups[@]}"; do
    echo "Regrouping to \$group using safe_regroup.py"
    
    # Use safe_regroup.py instead of humann_regroup_table
    safe_regroup.py \\
      ${run}_genefamilies.biom \\
      \$group \\
      ${run}_genefamilies.\${group}.biom \\
      ${params.split_size ?: 100}
  done

  echo "Processing complete"
  """
}

process convert_tables_to_biom {
  tag "${run}_${type}"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/combined_tables" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/pathabundance" }, mode: 'copy', pattern: "*_pathabundance.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/reactions" }, mode: 'copy', pattern: "*_reactions.biom"
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
  table_type = (type == 'humann_taxonomy') ? 'Taxon table' : 'Function table'
  """
  echo "Converting ${type} table to biom format"
  biom convert \\
    --input-fp ${table} \\
    --output-fp ${run}_${type}.biom \\
    --table-type '${table_type}' \\
    --to-hdf5
  """
}

process split_stratified_tables {
  tag "${run}_${type}"

  container params.docker_container_humann4

  publishDir {"${params.outdir}/${params.project}/${run}/combined_unstratified" }, mode: 'copy', pattern: "*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/genefamilies/unstratified" }, mode: 'copy', pattern: "*genefamilies_*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/pathabundance/unstratified" }, mode: 'copy', pattern: "*pathabundance_*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/reactions/unstratified" }, mode: 'copy', pattern: "*reactions_*.biom"
  publishDir {"${params.outdir}/${params.project}/combined_bioms/regrouped/unstratified" }, mode: 'copy', pattern: "*uniref90_*.biom"

  input:
  tuple val(meta), path(biom_table)

  output:
  tuple val(meta), path("*.biom"), emit: unstratified_tables

  when:
  params.annotation

  script:
  run = task.ext.run ?: "${meta.run}"
  type = task.ext.type ?: "${meta.type}"
  """
  echo "Splitting stratified table: ${biom_table} (type: ${type})"
  
  # Split stratified table to get unstratified version
  humann_split_stratified_table \\
    -i ${biom_table} \\
    -o .
    
  # List what was created
  echo "Unstratified files created:"
  ls -la *.biom
  """
}

