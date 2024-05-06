#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { profile_taxa; profile_function; combine_humann_tables; combine_metaphlan_tables } from './modules/community_characterisation'
include { MULTIQC; merge_paired_end_cleaned; clean_single_end; clean_paired_end; get_software_versions; cat_fastqs} from './modules/house_keeping'
include { samplesheetToList           } from 'plugin/nf-schema'

def versionMessage()
{
  log.info"""

  nf-reads-profiler - Version: ${workflow.manifest.version}
  """.stripIndent()
}

def helpMessage()
{
  log.info"""

nf-reads-profiler - Version: ${workflow.manifest.version}

  Mandatory arguments:
    --reads1   R1      Forward (if paired-end) OR all reads (if single-end) path path
    [--reads2] R2      Reverse reads file path (only if paired-end library layout)
    --prefix   prefix  Prefix used to name the result files
    --outdir   path    Output directory (will be outdir/prefix/)

  Main options:
    --singleEnd  <true|false>   whether the layout is single-end

  Other options:
  MetaPhlAn parameters for taxa profiling:
    --metaphlan_db path   folder for the MetaPhlAn database
    --bt2options          value   BowTie2 options

  HUMANn parameters for functional profiling:
    --taxonomic_profile   path    s3path to precalculate metaphlan3 taxonomic profile output.
    --chocophlan          path    folder for the ChocoPhlAn database
    --uniref              path    folder for the UniRef database
    --annotation  <true|false>   whether annotation is enabled (default: false)

nf-reads-profiler supports FASTQ and compressed FASTQ files.
"""
}

/**
Prints version when asked for
*/
if (params.version) {
  versionMessage()
  exit 0
}

/**
Prints help when asked for
*/

if (params.help) {
  helpMessage()
  exit 0
}


//Creates working dir
workingpath = params.outdir + "/" + params.project
workingdir = file(workingpath)
if( !workingdir.exists() ) {
  if( !workingdir.mkdirs() )  {
    exit 1, "Cannot create working directory: $workingpath"
  }
}


// Header log info
log.info """---------------------------------------------
nf-reads-profiler
---------------------------------------------

Analysis introspection:

"""

def summary = [:]

summary['Starting time'] = new java.util.Date()
//Environment
summary['Environment'] = ""
summary['Pipeline Name'] = 'nf-reads-profiler'
summary['Pipeline Version'] = workflow.manifest.version

summary['Config Profile'] = workflow.profile
summary['Resumed'] = workflow.resume

summary['Nextflow version'] = nextflow.version.toString() + " build " + nextflow.build.toString() + " (" + nextflow.timestamp + ")"

summary['Java version'] = System.getProperty("java.version")
summary['Java Virtual Machine'] = System.getProperty("java.vm.name") + "(" + System.getProperty("java.vm.version") + ")"

summary['Operating system'] = System.getProperty("os.name") + " " + System.getProperty("os.arch") + " v" +  System.getProperty("os.version")
summary['User name'] = System.getProperty("user.name") //User's account name

summary['Container Engine'] = workflow.containerEngine
if(workflow.containerEngine) summary['Container'] = workflow.container
summary['HUMAnN'] = params.docker_container_humann3
summary['MetaPhlAn'] = params.docker_container_metaphlan
summary['MultiQC'] = params.docker_container_multiqc

//General
summary['Running parameters'] = ""
summary['Sample Sheet'] = params.input
summary['Layout'] = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Data Type'] = params.rna ? 'Metatranscriptomic' : 'Metagenomic'
summary['Merge Reads'] = params.mergeReads

//BowTie2 databases for metaphlan
summary['MetaPhlAn parameters'] = ""
summary['MetaPhlAn database'] = params.metaphlan_db
summary['Bowtie2 options'] = params.bt2options

// ChocoPhlAn and UniRef databases
summary['HUMAnN parameters'] = ""
summary['Taxonomic Profile'] = params.taxonomic_profile
summary['Chocophlan database'] = params.chocophlan
summary['Uniref database'] = params.uniref

//Folders
summary['Folders'] = ""
summary['Output dir'] = workingpath
summary['Working dir'] = workflow.workDir
summary['Output dir'] = params.outdir
summary['Script dir'] = workflow.projectDir
summary['Lunching dir'] = workflow.launchDir

log.info summary.collect { k,v -> "${k.padRight(27)}: $v" }.join("\n")
log.info ""


/**
  Prepare workflow introspection

  This process adds the workflow introspection (also printed at runtime) in the logs
  This is NF-CORE code.
*/

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve("workflow_summary_mqc.yaml")
    yaml_file.text  = """
    id: 'workflow-summary'
    description: "This information is collected when the pipeline is started."
    section_name: 'nf-reads-profiler Workflow Summary'
    section_href: 'https://github.com/fischbachlab/nf-reads-profiler'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd>$v</dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}





workflow PIPELINE_INITIALISATION {
  // adapted from taxprofiler
  take:
  input             //  string: Path to input samplesheet

  main:
  //
  // Create channel from input file provided through params.input
  //
  Channel.fromList(samplesheetToList(params.input, "assets/schema_input.json"))
      .branch { meta, fastq_1, fastq_2 ->
        single: fastq_2 == []
          return tuple(meta, [fastq_1])
        paired: fastq_2 != []
          return tuple(meta, [fastq_1, fastq_2])
      }
      .set { input }
  
  // ch_samplesheet = input.single.mix(input.paired)

  emit:
  ch_single = input.single
  ch_paired = input.paired

}

workflow {
  to_profile_taxa_functions = Channel.empty()

  // read sample sheet
  PIPELINE_INITIALISATION(params.input)

  clean_single_end(PIPELINE_INITIALISATION.out.ch_single)
  clean_paired_end(PIPELINE_INITIALISATION.out.ch_paired)

  merged_reads = clean_single_end.out.reads_cleaned.mix(clean_paired_end.out.reads_cleaned)

  // profile taxa
  profile_taxa(merged_reads)

  // profile function
  profile_function(merged_reads, profile_taxa.out.to_profile_function_bugs)
  // profile_taxa.out.view()

  // regroup metadata
  ch_genefamilies = profile_function.out.profile_function_gf
              .map {
                meta, table ->
                    def meta_new = meta - meta.subMap('id')
                meta_new.put('type','genefamilies')
                [ meta_new, table ]
              }
              .groupTuple()
  ch_pathabundance = profile_function.out.profile_function_pa
              .map {
                meta, table ->
                    def meta_new = meta - meta.subMap('id')
                meta_new.put('type','pathabundance')
                [ meta_new, table ]
              }
              .groupTuple()
  ch_pathcoverage = profile_function.out.profile_function_pc
            .map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              meta_new.put('type','pathcoverage')
              [ meta_new, table ]
            }
            .groupTuple()

  ch_metaphlan = profile_taxa.out.to_profile_function_bugs
            .map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              [ meta_new, table ]
            }
            .groupTuple()

  combine_humann_tables(ch_genefamilies.mix(ch_pathcoverage, ch_pathabundance))
  combine_metaphlan_tables(ch_metaphlan)

  get_software_versions()
	ch_multiqc_config = Channel.fromPath("$projectDir/conf/multiqc_config.yaml", checkIfExists: true)
  ch_multiqc_files = Channel.empty()
  ch_multiqc_files = ch_multiqc_files.mix(get_software_versions.out.software_versions_yaml)
  ch_multiqc_files = ch_multiqc_files.mix(clean_single_end.out.fastp_log.collect().ifEmpty([]))
  ch_multiqc_files = ch_multiqc_files.mix(clean_paired_end.out.fastp_log.collect().ifEmpty([]))
  ch_multiqc_files = ch_multiqc_files.mix(profile_taxa.out.profile_taxa_log.collect().ifEmpty([]))
  ch_multiqc_files = ch_multiqc_files.mix(profile_function.out.profile_function_log.collect().ifEmpty([]))

  MULTIQC (
      ch_multiqc_files.collect(),
      ch_multiqc_config.toList()
  )
}
