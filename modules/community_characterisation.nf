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
  tuple val(meta), path("*_metaphlan_bugs_list.tsv"), emit: to_profile_function_bugs
  tuple val(meta), path("*_profile_taxa_mqc.yaml"), emit: profile_taxa_log


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
    --nproc ${task.cpus} \\
    --no_map \\
    $reads \\
    ${name}_metaphlan_bugs_list.tsv 1> profile_taxa_mqc.txt

  # MultiQC doesn't have a module for Metaphlan yet. As a consequence, I
  # had to create a YAML pathwith all the info I need via a bash script
  bash scrape_profile_taxa_log.sh ${name}_metaphlan_bugs_list.tsv > ${name}_profile_taxa_mqc.yaml
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

  publishDir {"${params.outdir}/${params.project}/${run}/function" }, mode: 'copy', pattern: "*.{tsv,log}"
  
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
  humann_join_tables \\
    -i ./ \\
    -o ${run}_${type}_combined.tsv \\
    --file_name ${type}
  """
}

process combine_metaphlan_tables {
  tag "$run"

  container params.docker_container_metaphlan

  publishDir {"${params.outdir}/${params.project}/${run}/taxa" }, mode: 'copy', pattern: "*.{tsv,log}"
  
  input:
  tuple val(meta), path(table)

  output:
  tuple val(meta), path('*.tsv')

  script:
  run = task.ext.run ?: "${meta.run}"
  """
  merge_metaphlan_tables.py ${table} \\
    -o ${run}_bugs_list_combined.tsv
  """
}

