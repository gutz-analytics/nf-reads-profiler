#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { profile_taxa; profile_function; combine_humann_tables; combine_metaphlan_tables } from './modules/community_characterisation'
include { MULTIQC; get_software_versions; clean_reads; count_reads} from './modules/house_keeping'
include { AWS_DOWNLOAD; FASTERQ_DUMP  } from './modules/data_handling'
include { samplesheetToList } from 'plugin/nf-schema'

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
    --skipHumann <true|false>   skip HUMAnN3 functional profiling and downstream steps (default: false)

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

// Ensure skipHumann is a boolean
params.skipHumann = params.skipHumann ? params.skipHumann.toString().toBoolean() : false

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


def output_exists(meta) {
  run = meta.run
  name = meta.id
  pathcoverage_file = file("${params.outdir}/${params.project}/${run}/function/${name}_pathcoverage.tsv")
  genefamilies_file = file("${params.outdir}/${params.project}/${run}/function/${name}_genefamilies.tsv")
  pathabundance_file = file("${params.outdir}/${params.project}/${run}/function/${name}_pathabundance.tsv")
  return pathcoverage_file.exists() && genefamilies_file.exists() && pathabundance_file.exists()
}


workflow {
  // Parse input samplesheet using nf-validation plugin
  Channel.fromList(samplesheetToList(params.input, "assets/schema_input.json"))
      .branch {
          local: it[1]                                    // Has fastq_1 defined
          sra: !it[1] && it[3] =~ /^[ESD]RR[0-9]+$/     // No local files but has SRA accession
      }
      .set { input_ch }

  // Process local files
  input_ch.local
      .map { meta, fastq_1, fastq_2, sra_id -> 
          meta.single_end = !fastq_2  // true if fastq_2 is empty/null
          fastq_2 ? [ meta, [ fastq_1, fastq_2 ] ] : [ meta, [ fastq_1 ] ]
      }
      .set { local_reads }

  // Process SRA files - only for samples without local files
  input_ch.sra
      .map { meta, fastq_1, fastq_2, sra_id ->
          [ meta, sra_id ]
      }
      .set { sra_ids }

  AWS_DOWNLOAD(sra_ids)

  def sortReads = { reads -> 
      reads.sort() 
  }

  // FASTERQ_DUMP(AWS_DOWNLOAD.out.sra_file)
  //     .reads
  //     .map { meta, reads -> 
  //         meta.single_end = reads.size() == 1
  //         [ meta, sortReads(reads) ]
  //     }
  //     .set { sra_reads }
  FASTERQ_DUMP(AWS_DOWNLOAD.out.sra_file)
    .reads
    .map { meta, raw_reads ->
        // If raw_reads is a single Path, wrap it in a list
        def reads = (raw_reads instanceof List) ? raw_reads : [ raw_reads ]

        meta.single_end = (reads.size() == 1)
        [ meta, reads.sort() ]
    }
    .set { sra_reads }

  // Merge all read channels
  reads_ch = Channel.empty()
      .mix(local_reads)
      .mix(sra_reads)

    // Count reads and filter samples
    count_reads(reads_ch)
    
    // Split into passing and failing samples based on read count
    count_reads.out.read_info
        .branch {
            pass: it[2].toInteger() >= params.minreads
            fail: true
        }
        .set { read_check }
    
    // Log filtered samples
    read_check.fail
        .map { meta, reads, count -> 
            log.info "Skipping sample ${meta.id} due to insufficient reads: ${count} < ${params.minreads}"
        }

    // Process passing samples
    clean_reads(read_check.pass.map { meta, reads, count -> [meta, reads] })

  merged_reads = clean_reads.out.reads_cleaned

  // profile taxa
  profile_taxa(merged_reads)


  ch_filtered_reads = merged_reads.filter { meta, reads -> !output_exists(meta) }
  

  // Functional profiling (HUMAnN4) if not skipped
  if ( ! params.skipHumann ) {
    profile_function(merged_reads)

    ch_genefamilies = profile_function.out.profile_function_gf
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','genefamilies')
                    [ meta_new, table ]
                }
                .groupTuple()

    ch_reactions = profile_function.out.profile_function_reactions
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','reactions')
                    [ meta_new, table ]
                }
                .groupTuple()

    ch_pathabundance = profile_function.out.profile_function_pa
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','pathabundance')
                    [ meta_new, table ]
                }
                .groupTuple()

    // HUMAnN-generated taxonomy profiles (separate from independent MetaPhlAn)
    ch_humann_taxonomy = profile_function.out.profile_function_metaphlan
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','metaphlan_profile')
                    [ meta_new, table ]
                }
                .groupTuple()

    combine_humann_tables(ch_genefamilies.mix(ch_reactions, ch_pathabundance, ch_humann_taxonomy))
  }


  // Metaphlan
  ch_metaphlan = profile_taxa.out.to_profile_function_bugs
            .map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              [ meta_new, table ]
            }
            .groupTuple()
            
  combine_metaphlan_tables(ch_metaphlan)

  // MultiQC setup
  ch_multiqc_files = Channel.empty()
  ch_multiqc_files = ch_multiqc_files.concat(clean_reads.out.fastp_log.ifEmpty([]))
  ch_multiqc_files = ch_multiqc_files.concat(profile_taxa.out.profile_taxa_log.ifEmpty([]))
  if ( ! params.skipHumann ) {
    ch_multiqc_files = ch_multiqc_files.concat(profile_function.out.profile_function_log.ifEmpty([]))
  }
  

  ch_multiqc_config = Channel.fromPath("$projectDir/conf/multiqc_config.yaml", checkIfExists: true)

  ch_multiqc_runs = ch_multiqc_files.map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              [ meta_new, table ]
            }
            .groupTuple()
  get_software_versions()
  MULTIQC (
    get_software_versions.out.software_versions_yaml,
    ch_multiqc_runs,
    ch_multiqc_config.toList()
  )
}
