
/**
  Gets software version.

  This process ensures that software version are included in the logs.
*/

process get_software_versions {

  //Starting the biobakery container. I need to run metaphlan and Humann to get
  //their version number (due to the fact that they live in the same container)
  container params.docker_container_multiqc

  //input:
  //val (some_value)

  output:
  path "software_versions_mqc.yaml", emit: software_versions_yaml

  script:
  //I am using a multi-containers scenarios, supporting docker and singularity
  //with the software at a specific version (the same for all platforms). Therefore, I
  //will simply parse the version from there. Perhaps overkill, but who cares?
  //This is not true for the biobakery suite (metaphlan/humann) which extract the
  //information at runtime from the actual commands (see comment above)
  """
  echo $workflow.manifest.version > v_pipeline.txt
  echo $workflow.nextflow.version > v_nextflow.txt

  echo $params.docker_container_fastp | cut -d: -f 2 > v_fastp.txt
  echo $params.docker_container_humann3 | cut -d: -f 2 > v_humann.txt
  echo $params.docker_container_metaphlan | cut -d: -f 2 > v_metaphlan.txt
  echo $params.docker_container_multiqc | cut -d: -f 2 > v_multiqc.txt

  scrape_software_versions.py > software_versions_mqc.yaml
  """
}

process cat_fastqs {
  tag "$name"
  container params.docker_container_bbmap

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_cat.fq.gz"), emit: reads_merged

  script:
  name = task.ext.name ?: "${meta.id}"
  """
  cat ${reads} > ${name}_cat.fq.gz
  """  
}

process clean_single_end {
  tag "$name"
  label "fastp"
  container params.docker_container_fastp

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_trimmed.fq.gz"), emit: reads_cleaned
  tuple val(meta), path("*_fastp.json"), emit: fastp_log

  script:
  name = task.ext.name ?: "${meta.id}"

  """
  fastp \\
  -i ${reads[0]} \\
  -o ${name}_trimmed.fq.gz \\
  --reads_to_process ${params.nreads} \\
  --dedup \\
  --disable_quality_filtering \\
  --json ${name}_fastp.json \\
  --thread ${task.cpus}
  """
}
process clean_paired_end {
  tag "$name"
  label "fastp"
  container params.docker_container_fastp

  input:
  tuple val(meta), path(reads)

  output:
  tuple val(meta), path("*_trimmed.fq.gz"), emit: reads_cleaned
  tuple val(meta), path("*_fastp.json"), emit: fastp_log

  script:
  name = task.ext.name ?: "${meta.id}"

  """
  fastp \\
  -i ${reads[0]} \\
  -I ${reads[1]} \\
  -o out.R1.fq.gz \\
  -O out.R2.fq.gz \\
  --reads_to_process ${params.nreads} \\
  --dedup \\
  --disable_quality_filtering \\
  --json ${name}_fastp.json \\
  --thread ${task.cpus}

  cat out.R1.fq.gz out.R2.fq.gz > ${name}_trimmed.fq.gz
  """
}

process merge_paired_end_cleaned {

  tag "$name"
  container params.docker_container_bbmap

  input:
  tuple val(name), path(reads)

  output:
  tuple val(name), path("*_QCd.fq.gz"), emit: to_profile_taxa_merged
  tuple val(name), path("*_QCd.fq.gz"), emit: to_profile_functions_merged

  when:
  !params.singleEnd

    script:
  """
  # This step will have no logging because the information are not relevant
  # I will simply use a boilerplate YAML to record that this has happened
  # If the files were not compressed, they will be at this stage

  #Sets the maximum memory to the value requested in the config file
    maxmem=\$(echo \"$task.memory\" | sed 's/ //g' | sed 's/B//g')

  reformat.sh -Xmx\"\$maxmem\" in1=${reads[0]} in2=${reads[1]} out=${name}_QCd.fq.gz threads=${task.cpus}
  """
}

// ------------------------------------------------------------------------------
//  MULTIQC LOGGING
// ------------------------------------------------------------------------------


/**
  Generate Logs.

  Logs generate at each analysis step are collected and processed with MultiQC
*/


process log {

  publishDir "${params.outdir}/${params.project}/log", mode: 'copy'

  container params.docker_container_multiqc

  input:
  path multiqc_config
  path software_versions
  path fastp_single
  path fastp_paired
  path profile_taxa
  path profile_function

  output:
  path "multiqc_report.html"
  path "multiqc_data"

  script:
  """
  multiqc --config $multiqc_config . -f
  """
}



