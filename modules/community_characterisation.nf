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

	publishDir "${params.outdir}/${params.project}/${params.prefix}/taxa", mode: 'copy', pattern: "*.{biom,tsv,txt,bz2}"

	input:
	tuple val(name), path(reads)

	output:
	tuple val(name), path("*.biom")
	tuple val(name), path("*_metaphlan_bugs_list.tsv"), emit: to_profile_function_bugs
	path "profile_taxa_mqc.yaml", emit: profile_taxa_log


	when:
	!params.rna

	script:
	"""
	echo ${params.metaphlan_db}

	metaphlan \\
		--input_type fastq \\
		--tmp_dir . \\
		--biom ${name}.biom \\
		--index ${params.metaphlan_index} \\
		--bowtie2db ${params.metaphlan_db} \\
		--bt2_ps ${params.bt2options} \\
		--add_viruses \\
		--sample_id ${name} \\
		--nproc ${task.cpus} \\
		--unclassified_estimation \\
		--no_map \\
		$reads \\
		${name}_metaphlan_bugs_list.tsv 1> profile_taxa_mqc.txt

	# MultiQC doesn't have a module for Metaphlan yet. As a consequence, I
	# had to create a YAML pathwith all the info I need via a bash script
	bash scrape_profile_taxa_log.sh ${name}_metaphlan_bugs_list.tsv > profile_taxa_mqc.yaml
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
  container params.docker_container_humann3

	publishDir {params.rna ? "${params.outdir}/${params.project}/${params.prefix}/function/metaT" : "${params.outdir}/${params.project}/${params.prefix}/function/metaG" }, mode: 'copy', pattern: "*.{tsv,log}"

	input:
	tuple val(name), path(reads)
	tuple val(name), path(metaphlan_bug_list)

  output:
	path "*_HUMAnN.log"
	path "*_genefamilies.tsv"
	path "*_pathcoverage.tsv"
	path "*_pathabundance.tsv"
	path "profile_functions_mqc.yaml", emit: profile_function_log

	when:
	params.annotation

	script:
	"""
	head -n 3 ${metaphlan_bug_list}
	ls -lhtr ${metaphlan_bug_list}
	#HUMAnN will use the list of species detected by the profile_taxa process
	humann \\
		--input $reads \\
		--output . \\
		--output-basename ${name} \\
		--taxonomic-profile ${metaphlan_bug_list} \\
		--nucleotide-database ${params.chocophlan} \\
		--protein-database ${params.uniref} \\
		--pathways metacyc \\
		--threads ${task.cpus} \\
		--memory-use minimum &> ${name}_HUMAnN.log

	# MultiQC doesn't have a module for humann yet. As a consequence, I
	# had to create a YAML file with all the info I need via a bash script
	bash scrape_profile_functions.sh ${name} ${name}_HUMAnN.log > profile_functions_mqc.yaml
 	"""
}


