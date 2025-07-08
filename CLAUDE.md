# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Nextflow pipeline for metagenomic read profiling using MetaPhlAn4 and HUMAnN3. The pipeline is based on the original YAMP repository but has been modified for Azure Batch execution with containerized bioinformatics tools.

## Common Commands

### Running the Pipeline

**Local testing:**
```bash
nextflow run main.nf -profile test
```

**Azure Batch execution:**
```bash
nextflow run main.nf -profile azure --input samplesheet.csv --project <project_name> --outdir <output_path>
```

**AWS Batch execution (legacy):**
```bash
aws batch submit-job \
    --job-name nf-rp-<name> \
    --job-queue priority-maf-pipelines \
    --job-definition nextflow-production \
    --container-overrides command=fischbachlab/nf-reads-profiler,\
"--prefix","<prefix>",\
"--singleEnd","false",\
"--reads1","<s3_path_to_R1>",\
"--reads2","<s3_path_to_R2>"
```

### Testing

**Run tests using nf-test:**
```bash
nf-test test
```

**Run with test configuration:**
```bash
nextflow run main.nf -c conf/test.config
```

### Development

**Check pipeline syntax:**
```bash
nextflow run main.nf --help
```

**Validate samplesheet:**
```bash
nextflow run main.nf --input <samplesheet.csv> --help
```

## Architecture

### Core Workflow Structure

The pipeline is organized into three main process groups:

1. **Data Handling (`modules/data_handling.nf`)**
   - `AWS_DOWNLOAD`: Downloads SRA files from S3
   - `FASTERQ_DUMP`: Converts SRA files to FASTQ format

2. **Community Characterization (`modules/community_characterisation.nf`)**
   - `profile_taxa`: Taxonomic profiling using MetaPhlAn4
   - `profile_function`: Functional profiling using HUMAnN3
   - `combine_humann_tables`: Combines HUMAnN3 output tables
   - `combine_metaphlan_tables`: Combines MetaPhlAn4 output tables

3. **House Keeping (`modules/house_keeping.nf`)**
   - `clean_reads`: Quality control and trimming with fastp
   - `count_reads`: Read counting and filtering
   - `get_software_versions`: Software version tracking
   - `MULTIQC`: Quality control report generation

### Input Data Flow

The pipeline supports two input modes:
- **Local files**: FASTQ files provided directly via samplesheet
- **SRA accessions**: Downloads from NCBI SRA using AWS S3 mirror

Input validation is handled through `assets/schema_input.json` using nf-schema plugin.

### Configuration Profiles

- `test`: Local testing with small datasets and test databases
- `azure`: Azure Batch execution with full-scale databases
- `aws`: AWS Batch execution (legacy, commented out)

### Container Strategy

All processes use containerized tools from Azure Container Registry:
- MetaPhlAn4: `gutzcontainers.azurecr.io/metaphlan:4.1.0`
- HUMAnN3: `gutzcontainers.azurecr.io/humann:3.9`
- fastp: `gutzcontainers.azurecr.io/fastp:0.23.4`
- MultiQC: `gutzcontainers.azurecr.io/multiqc:1.11`

### Database Requirements

**MetaPhlAn4 databases:**
- Located at `/dbs/metagenometest/metagenome-dbs/metaphlan/metaphlan4/vJun23`
- Index: `mpa_vJun23_CHOCOPhlAnSGB_202307`

**HUMAnN3 databases:**
- ChocoPhlAn: `/dbs/metagenometest/metagenome-dbs/humann/3.0/chocophlan/`
- UniRef90: `/dbs/metagenometest/metagenome-dbs/humann/3.0/uniref/`
- Utility mapping: `/dbs/metagenometest/metagenome-dbs/humann/3.0/utility_mapping/`

### Key Parameters

- `skipHumann`: Skip functional profiling (default: false)
- `singleEnd`: Single-end reads mode (default: false)
- `nreads`: Limit number of reads processed (default: 33333333)
- `minreads`: Minimum reads required per sample (default: 100000)
- `annotation`: Enable functional annotation (default: true)

### Output Structure

```
outdir/
├── project/
│   ├── study/
│   │   ├── taxa/           # MetaPhlAn4 taxonomic profiles
│   │   ├── function/       # HUMAnN3 functional profiles
│   │   └── log/           # MultiQC reports
│   └── execution_reports/ # Nextflow execution reports
```

### Error Handling

The pipeline uses an `ignore` error strategy with retry logic for Azure Batch processes. Failed samples are logged but do not stop the pipeline execution.

### Resource Management

Azure Batch pools are auto-scaled based on workload:
- Standard_E4s_v3: General processing
- Standard_E8ads_v5: CPU-intensive tasks (HUMAnN3)
- Standard_D8ads_v5: Memory-intensive tasks (MetaPhlAn4)
- Standard_E32s_v3: MultiQC report generation