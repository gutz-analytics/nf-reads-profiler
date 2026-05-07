#!/usr/bin/env nextflow

include { profile_taxa; profile_function; combine_humann_tables; combine_metaphlan_tables; combine_humann_taxonomy_tables; convert_tables_to_biom; split_stratified_tables; regroup_genefamilies } from './modules/community_characterisation'
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
    --skipHumann <true|false>   skip HUMAnN4 functional profiling and downstream steps (default: false)

  Other options:
  MetaPhlAn parameters for taxa profiling:
    --direct_metaphlan_id name    Name/ID of the MetaPhlAn database, e.g. "mpa_vJan25_CHOCOPhlAnSGB_202503"
    --direct_metaphlan_db path    folder for the MetaPhlAn database
    --direct_bt2options   value   BowTie2 options (direct MetaPhlAn)

  HUMANn parameters for functional profiling:
    --humann_metaphlan_id name    Name/ID of the MetaPhlAn database, e.g. "mpa_vOct22_CHOCOPhlAnSGB_202403"
    --humann_metaphlan_db path    folder for the MetaPhlAn database
    --humann_chocophlan   path    folder for the ChocoPhlAn database
    --humann_uniref       path    folder for the UniRef database
    --humann_utilitymap   path    folder for the HUMAnN utility mapping database
    --humann_bt2options   value   BowTie2 options (internal MetaPhlAn)

nf-reads-profiler supports FASTQ and compressed FASTQ files.
"""
}

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
  if (!params.skipCompleted) return false
  def run = meta.run
  def name = meta.id
  def genefamilies_file = file("${params.outdir}/${params.project}/${run}/function/${name}_2_genefamilies.tsv")
  def reactions_file = file("${params.outdir}/${params.project}/${run}/function/${name}_3_reactions.tsv")
  def pathabundance_file = file("${params.outdir}/${params.project}/${run}/function/${name}_4_pathabundance.tsv")
  return genefamilies_file.exists() && reactions_file.exists() && pathabundance_file.exists()
}


workflow {

  // Handle --version and --help
  if (params.version) {
    versionMessage()
    exit 0
  }
  if (params.help) {
    helpMessage()
    exit 0
  }

  //Creates working dir
  def workingpath = params.outdir + "/" + params.project
  def workingdir = file(workingpath)
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
  summary['HUMAnN'] = params.docker_container_humann4
  summary['MetaPhlAn'] = params.docker_container_metaphlan
  summary['MultiQC'] = params.docker_container_multiqc

  //General
  summary['Running parameters'] = ""
  summary['Sample Sheet'] = params.input
  summary['Layout'] = params.singleEnd ? 'Single-End' : 'Paired-End'
  summary['Merge Reads'] = params.mergeReads

  //BowTie2 databases for metaphlan
  summary['MetaPhlAn parameters'] = ""
  summary['MetaPhlAn database'] = params.direct_metaphlan_db
  summary['Bowtie2 options (direct)'] = params.direct_bt2options
  summary['Bowtie2 options (humann)'] = params.humann_bt2options

  // ChocoPhlAn and UniRef databases
  summary['HUMAnN parameters'] = ""
  summary['Chocophlan database'] = params.humann_chocophlan
  summary['Uniref database'] = params.humann_uniref

  //Folders
  summary['Folders'] = ""
  summary['Output dir'] = workingpath
  summary['Working dir'] = workflow.workDir
  summary['Output dir'] = params.outdir
  summary['Script dir'] = workflow.projectDir
  summary['Lunching dir'] = workflow.launchDir

  log.info summary.collect { k,v -> "${k.padRight(27)}: $v" }.join("\n")
  log.info ""
  // Parse input samplesheet using nf-validation plugin
  channel.fromList(samplesheetToList(params.input, "assets/schema_input.json"))
      .branch { row ->
          local: row[1]                                    // Has fastq_1 defined
          sra: !row[1] && row[3] =~ /^[ESD]RR[0-9]+$/     // No local files but has SRA accession
      }
      .set { input_ch }

  // Process local files
  input_ch.local
      .map { meta, fastq_1, fastq_2, _sra_id ->
          meta.single_end = !fastq_2  // true if fastq_2 is empty/null
          fastq_2 ? [ meta, [ fastq_1, fastq_2 ] ] : [ meta, [ fastq_1 ] ]
      }
      .set { local_reads }

  // Process SRA files - only for samples without local files
  input_ch.sra
      .map { meta, _fastq_1, _fastq_2, sra_id ->
          [ meta, sra_id ]
      }
      .set { sra_ids }

  AWS_DOWNLOAD(sra_ids)

  // def sortReads = { reads ->
  //     reads.sort()
  // }
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
  reads_ch = channel.empty()
      .mix(local_reads)
      .mix(sra_reads)

    // Count reads and filter samples
    count_reads(reads_ch)
    
    // Split into passing and failing samples based on read count
    count_reads.out.read_info
        .branch { row ->
            pass: row[2].toInteger() >= params.minreads
            fail: true
        }
        .set { read_check }
    
    // Log filtered samples
    read_check.fail
        .map { meta, _reads, count ->
            log.info "Skipping sample ${meta.id} due to insufficient reads: ${count} < ${params.minreads}"
        }

    // Process passing samples
    clean_reads(read_check.pass.map { meta, reads, _count -> [meta, reads] })

  merged_reads = clean_reads.out.reads_cleaned

  // profile taxa
  profile_taxa(merged_reads)


  ch_filtered_reads = merged_reads.filter { meta, reads -> !output_exists(meta) }

  // Functional profiling (HUMAnN4) if not skipped
  if ( ! params.skipHumann ) {
    profile_function(ch_filtered_reads)

    ch_genefamilies = profile_function.out.profile_function_gf
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','genefamilies')
                    [ meta_new, table ]
                }
                .groupTuple(sort: true)

    ch_reactions = profile_function.out.profile_function_reactions
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','reactions')
                    [ meta_new, table ]
                }
                .groupTuple(sort: true)

    ch_pathabundance = profile_function.out.profile_function_pa
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','pathabundance')
                    [ meta_new, table ]
                }
                .groupTuple(sort: true)

    // HUMAnN-generated taxonomy profiles (separate from independent MetaPhlAn)
    ch_humann_taxonomy = profile_function.out.profile_function_metaphlan
                .map { meta, table ->
                    def meta_new = meta - meta.subMap('id')
                    meta_new.put('type','metaphlan_profile')
                    [ meta_new, table ]
                }
                .groupTuple(sort: true)

    combine_humann_tables(ch_genefamilies.mix(ch_reactions, ch_pathabundance))
    
    // Also combine HUMAnN-generated taxonomy profiles
    combine_humann_taxonomy_tables(ch_humann_taxonomy)
    
    // Get output tsv tables for conversion to biom
    ch_tables_for_splitting = combine_humann_tables.out
    
    // Add combined HUMAnN taxonomy tables to biom conversion
    ch_humann_taxonomy_for_biom = combine_humann_taxonomy_tables.out.combined_tsv
                .map { meta, table ->
                    def meta_new = meta.clone()
                    meta_new.put('type','humann_taxonomy')
                    [ meta_new, table ]
                }
    
  }


  // Metaphlan
  ch_metaphlan = profile_taxa.out.to_profile_function_bugs
            .map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              [ meta_new, table ]
            }
            .groupTuple(sort: true)
            
  combine_metaphlan_tables(ch_metaphlan)

  // MEDI quantification workflow
  if (params.enable_medi) {
    if (!params.medi_db_path || !params.medi_food_matches || !params.medi_food_contents) {
      error "MEDI quantification requires: medi_db_path, medi_food_matches, and medi_food_contents"
    }
    if (params.skipHumann) {
      error "MEDI requires HUMAnN: remove --skipHumann or set --enable_medi false"
    }
    if (params.humann_extraparams.contains('--bypass-translated-search')) {
      error """\
        MEDI is enabled but humann_extraparams contains --bypass-translated-search.
        MEDI needs HUMAnN's fully-unaligned reads, which are only produced after
        the Diamond translated search. Remove --bypass-translated-search and rerun.
        """.stripIndent()
    }

    // HUMAnN fully-unaligned reads: already QC'd, ~5–20% of original read count.
    // HUMAnN merges paired reads internally so these are always single-end FASTA.
    //
    // groupTuple waits for all samples in a study to finish HUMAnN before emitting,
    // because it doesn't know the group size upfront. This serialises the HUMAnN →
    // MEDI handoff per study. In quant.nf, flatMap immediately breaks the group back
    // into per-sample items so Kraken2 runs in parallel. Net effect: all HUMAnN jobs
    // in a study must complete before any Kraken2 starts — acceptable for local
    // testing and small runs; revisit with groupTuple(size:) for large batches.
    profile_function.out.unmapped_reads
      .map { meta, fa -> [meta + [single_end: true], [fa]] }
      .map { meta, reads ->
        def group_meta = meta.subMap('run')
        [group_meta, meta, reads]
      }
      .groupTuple(by: [0])
      .map { group_meta, metas, reads_files ->
        def study = group_meta.run
        def samples = [metas, reads_files].transpose().collect { m, r -> [m, r] }
        [study, samples]
      }
      .set { studies_with_samples }

    MEDI_QUANT(
      studies_with_samples,
      params.medi_food_matches,
      params.medi_food_contents
    )
  }

  // Split stratified tables for biom files
  if (!params.skipHumann) {

    // Split output tsv into stratified and unstratified 

    // Split raw output tables into stratified and unstratified
    split_stratified_tables(ch_tables_for_splitting)

    // Disable biom convert for now. We will just to do the 'map' and we can 'reduce' later!

    // // Make channel for biom conversion - combine both stratified and unstratified outputs
    // ch_tables_for_biom = split_stratified_tables.out.stratified_tables
    //   .map { meta, file -> [meta + [stratification: 'stratified'], file] }
    //   .mix(split_stratified_tables.out.unstratified_tables
    //     .map { meta, file -> [meta + [stratification: 'unstratified'], file] })
    //   .mix(ch_humann_taxonomy_for_biom)

    // // Convert all tables to biom format
    // convert_tables_to_biom(ch_tables_for_biom)
    
    // // Process HUMAnN tables if enabled
    // if (params.humann_regroup) {
    //   // Use only the genefamilies combined tables for processing
    //   ch_combined_genefamilies = convert_tables_to_biom.out.filter { meta, table ->
    //     meta.type == 'genefamilies'
    //   }
    //   regroup_genefamilies(ch_combined_genefamilies)
    // }
    
  }

  // MultiQC setup
  ch_multiqc_files = channel.empty()
  ch_multiqc_files = ch_multiqc_files.mix(clean_reads.out.fastp_log)
  // ch_multiqc_files = ch_multiqc_files.mix(profile_taxa.out.profile_taxa_log)
  if ( ! params.skipHumann ) {
    ch_multiqc_files = ch_multiqc_files.mix(profile_function.out.profile_function_log)
  }
  

  ch_multiqc_config = channel.fromPath("$projectDir/conf/multiqc_config.yaml", checkIfExists: true)

  ch_multiqc_runs = ch_multiqc_files.map {
              meta, table ->
                  def meta_new = meta - meta.subMap('id')
              [ meta_new, table ]
            }
            .groupTuple(sort: true)
  get_software_versions()
  MULTIQC (
    get_software_versions.out.software_versions_yaml,
    ch_multiqc_runs,
    ch_multiqc_config.toList()
  )
}
