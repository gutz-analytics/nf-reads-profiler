#!/usr/bin/env nextflow

nextflow.enable.dsl=2

include { profile_taxa; profile_function } from './modules/community_characterisation'
include { MULTIQC; get_software_versions; clean_reads; count_reads} from './modules/house_keeping'
include { AWS_DOWNLOAD; FASTERQ_DUMP  } from './modules/data_handling'
include { MEDI_QUANT } from './subworkflows/quant'
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
  // Check for HUMAnN4 output files (numbered prefix convention: _2_, _3_, _4_)
  genefamilies_file = file("${params.outdir}/${params.project}/${run}/function/${name}_2_genefamilies.tsv")
  reactions_file = file("${params.outdir}/${params.project}/${run}/function/${name}_3_reactions.tsv")
  pathabundance_file = file("${params.outdir}/${params.project}/${run}/function/${name}_4_pathabundance.tsv")
  return genefamilies_file.exists() && reactions_file.exists() && pathabundance_file.exists()
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


  // Skip samples that already have completed HUMAnN output (avoids re-running 36h+ jobs)
  ch_filtered_reads = merged_reads.filter { meta, reads -> !output_exists(meta) }

  // Log skipped samples
  merged_reads.filter { meta, reads -> output_exists(meta) }
    .map { meta, reads -> log.info "Skipping HUMAnN for ${meta.id} (output already exists)" }

  // Functional profiling (HUMAnN4) if not skipped
  if ( ! params.skipHumann ) {
    // When reuse_metaphlan_profile is enabled, join MetaPhlAn TSV profiles with reads
    // so HUMAnN skips its internal MetaPhlAn run (~20min/sample savings).
    // This creates a serial dependency: profile_taxa must complete before profile_function.
    if (params.reuse_metaphlan_profile) {
      ch_humann_input = ch_filtered_reads
        .join(profile_taxa.out.metaphlan_tsv)
        .map { meta, reads, tsv_profile -> [meta, reads, tsv_profile] }
      log.info "HUMAnN will reuse MetaPhlAn profiles from profile_taxa (reuse_metaphlan_profile=true)"
    } else {
      // Default: no pre-computed profile, HUMAnN runs its own MetaPhlAn internally
      ch_humann_input = ch_filtered_reads
        .map { meta, reads -> [meta, reads, file('NO_TAXONOMY_PROFILE')] }
    }

    profile_function(ch_humann_input)
  }


  // MEDI quantification workflow
  if (params.enable_medi) {
    // Check that required MEDI parameters are set
    if (!params.medi_db_path || !params.medi_foods_file || !params.medi_food_contents_file) {
      error "MEDI quantification requires: medi_db_path, medi_foods_file, and medi_food_contents_file parameters"
    }

    // Choose MEDI input: unmapped reads from HUMAnN (if available) or all cleaned reads
    // When medi_unmapped_only=true and HUMAnN ran, MEDI gets only reads that didn't map
    // to any microbial gene database (ChocoPhlAn + UniRef). Since MEDI classifies
    // plant/animal food DNA, these populations barely overlap — saving ~27% on Kraken2.
    if (params.medi_unmapped_only && !params.skipHumann) {
      // Use HUMAnN-unmapped reads. For samples where HUMAnN was skipped (output_exists),
      // fall back to all cleaned reads since no unaligned file was produced.
      ch_humann_unaligned = profile_function.out.unaligned_reads

      // Samples that had existing HUMAnN output (skipped) still need MEDI on all reads
      ch_skipped_samples = merged_reads.filter { meta, reads -> output_exists(meta) }

      // Combine: unmapped reads for HUMAnN-processed samples + all reads for skipped samples
      medi_input_reads = ch_humann_unaligned.mix(ch_skipped_samples)

      log.info "MEDI will process HUMAnN-unmapped reads (medi_unmapped_only=true)"
    } else {
      // Default: MEDI gets all cleaned reads
      medi_input_reads = clean_reads.out.reads_cleaned
    }

    // Group reads by study for MEDI processing
    medi_input_reads
      .map{meta, reads ->
        def group_meta = meta.subMap('run')
        [group_meta, meta, reads]
      }
      .groupTuple(by: [0])
      .map{group_meta, metas, reads_files ->
        def study = group_meta.run
        def samples = [metas, reads_files].transpose().collect{meta, reads -> [meta, reads]}
        [study, samples]
      }
      .set{studies_with_samples}

    // Pass all studies to MEDI subworkflow - it will process each study group
    MEDI_QUANT(
      studies_with_samples,
      params.medi_foods_file,
      params.medi_food_contents_file,
      true  // reads are pre-cleaned by clean_reads, skip MEDI's own fastp
    )
  }

  // MultiQC setup
  ch_multiqc_files = Channel.empty()
  ch_multiqc_files = ch_multiqc_files.concat(clean_reads.out.fastp_log.ifEmpty([]))
  // ch_multiqc_files = ch_multiqc_files.concat(profile_taxa.out.profile_taxa_log.ifEmpty([]))
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
