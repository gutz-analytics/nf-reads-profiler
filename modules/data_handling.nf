process AWS_DOWNLOAD {
    tag "$meta.id"
    label 'process_low'

    conda "conda-forge::awscli"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/awscli:1.29.49' :
        'quay.io/biocontainers/awscli:1.29.49' }"

    input:
    tuple val(meta), val(sra_id)

    output:
    tuple val(meta), path("${sra_id}"), emit: sra_file
    path "versions.yml", emit: versions

    script:
    """
    aws s3 cp s3://sra-pub-run-odp/sra/${sra_id}/${sra_id} ${sra_id} --no-sign-request

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        aws-cli: \$(aws --version 2>&1 | cut -f1 -d' ' | cut -f2 -d'/')
    END_VERSIONS
    """
}

process FASTERQ_DUMP {
    tag "$meta.id"
    label 'process_medium'

    conda "bioconda::sra-tools=3.0.8"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/sra-tools:3.0.8--h9f5acd7_0' :
        'biocontainers/sra-tools:3.0.8--h9f5acd7_0' }"

    input:
    tuple val(meta), path(sra_file)

    output:
    tuple val(meta), path("processed/*.fastq.gz"), emit: reads
    path "versions.yml", emit: versions

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    # Run fasterq-dump
    fasterq-dump \\
        $args \\
        --threads $task.cpus \\
        --split-3 \\
        --mem ${task.memory.toGiga()}G \\
        $sra_file

    # Compress all fastq files
    pigz -p $task.cpus *.fastq

    # Create directory for processed files
    mkdir -p processed

    # Count files matching each pattern
    n1=\$(ls *_1.fastq.gz 2>/dev/null | wc -l)
    n2=\$(ls *_2.fastq.gz 2>/dev/null | wc -l)
    
    # Error if multiple _1 or _2 files
    if [ "\$n1" -gt 1 ] || [ "\$n2" -gt 1 ]; then
        echo "Error: Multiple files matching _1.fastq.gz or _2.fastq.gz pattern found!" >&2
        exit 1
    fi

    # Handle different file combinations
    if [ "\$n1" -eq 1 ] && [ "\$n2" -eq 1 ]; then
        # We have a proper pair of files
        mv *_1.fastq.gz processed/
        mv *_2.fastq.gz processed/
    elif [ "\$(ls *.fastq.gz | wc -l)" -eq 1 ]; then
        # Just one file
        mv *.fastq.gz processed/
    elif [ "\$n1" -eq 0 ] && [ "\$n2" -eq 0 ]; then
        # No paired files, just take the first one if multiple exist
        mv "\$(ls *.fastq.gz | head -n 1)" processed/
    else
        # Mismatched _1 and _2 files
        echo "Error: Mismatched _1 and _2 files found!" >&2
        exit 1
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        sratools: \$(fasterq-dump --version 2>&1 | grep -Eo '[0-9.]+')
        pigz: \$( pigz --version 2>&1 | sed 's/pigz //g' )
    END_VERSIONS
    """
}
