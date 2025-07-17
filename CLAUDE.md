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

## Critical Bug Fixes

### Data Loss Bug in safe_cluster_process.py (FIXED)

**Issue**: A critical bug was discovered where splits were overwriting each other's output files when processing large datasets, causing massive data loss. All splits were writing to the same output filename (e.g., `output_uniref90_ko.biom`), resulting in only the last split's data being preserved.

**Root Cause**: The `execute_command` function in `safe_cluster_process.py` was not generating unique output filenames for each split, causing them to overwrite each other.

**Solution**: Implemented unique filename generation using `split_id` parameter:
- Added `split_id` parameter to `execute_command` function
- Used regex pattern matching to automatically modify output filenames (e.g., `-o output.biom` becomes `-o output_split_1.biom`)
- This ensures each split writes to a unique file, preventing data loss

**Testing**: Updated all tests to use smaller max-samples values (changed from 50/1000 to 2) to force splitting and properly exercise the functionality.

## Multithreading Support

### Overview

`safe_cluster_process.py` now supports multithreaded processing for parallel execution of splits, providing significant performance improvements for large datasets.

### Usage

```bash
# Sequential processing (default)
python bin/safe_cluster_process.py input.biom "command {input}" --max-samples 100

# Parallel processing with 4 threads
python bin/safe_cluster_process.py input.biom "command {input}" --max-samples 100 --num-threads 4
```

### Performance Benefits

- **Sequential**: ~2.5 seconds for 150 samples
- **Parallel (3 threads)**: ~1.4 seconds for 150 samples
- **Speedup**: ~43% faster with 3 threads

### Nextflow Integration

The multithreading functionality is now integrated into the Nextflow workflow:

- **process_humann_tables**: Uses 64 threads (Azure Batch) or 1 thread (test profile)
- **split_stratified_tables**: Uses 64 threads (Azure Batch) or 1 thread (test profile)
- **Configurable split size**: `params.split_size` parameter controls memory management
- **Automatic thread inheritance**: Uses `${task.cpus}` to match allocated resources

### Technical Implementation

- **ThreadPoolExecutor**: Uses Python's concurrent.futures for parallel processing
- **Thread-safe logging**: Implements proper locking mechanisms for shared resources
- **Error handling**: Comprehensive exception handling for multithreaded operations
- **Directory management**: Proper handling of temporary directories and output locations

### Key Functions

- `process_single_split()`: New function designed for parallel processing of individual splits
- `execute_command()`: Enhanced to support unique output filenames and working directory specification
- Thread-safe file detection and pattern matching

### Testing

**Run multithreading tests:**
```bash
python tests/scripts/test_multithreading.py
```

**Run integration tests:**
```bash
python tests/run_integration_tests.py --test-filter multithreading
```

## Test Infrastructure

### Test Organization

The project uses a comprehensive test infrastructure with dedicated directories:

**Test Directory Structure:**
```
tests/
├── data/                  # Test data files
├── scripts/               # Individual test scripts
├── test_output/           # Dedicated output directory for all tests
├── wrappers/             # Docker wrapper scripts
└── run_integration_tests.py  # Integration test runner
```

**Global Docker Wrappers:**
- `tests/wrappers/humann_split_stratified_wrapper.sh`: Wrapper for HUMAnN split stratified table command
- `tests/wrappers/humann_regroup_wrapper.sh`: Wrapper for HUMAnN regroup table command

### Running Tests

**Full integration test suite:**
```bash
python tests/run_integration_tests.py
```

**Individual test execution:**
```bash
python tests/scripts/test_multithreading.py
python tests/scripts/test_equivalence.py
python tests/scripts/test_final_validation.py
```

### Test Coverage

The test suite includes 6 comprehensive tests:
1. **test_multithreading.py**: Tests parallel processing functionality
2. **test_equivalence.py**: Validates identical results between direct and clustered execution
3. **test_final_validation.py**: End-to-end validation with simple commands
4. **test_real_humann.py**: Tests with actual HUMAnN Docker containers
5. **test_safe_cluster_process.py**: Core functionality tests
6. **test_simple_humann.py**: Basic HUMAnN integration tests

## Known Issues and Troubleshooting

### Multithreading Implementation Status

**Current Status**: ✅ **FULLY RESOLVED** - All multithreading functionality is implemented, tested, and working correctly.

**Key Fixes Applied**:
- **Architectural improvements**: Eliminated working directory dependencies and temp directory issues
- **Test infrastructure**: Created dedicated test output directories and global Docker wrappers
- **Path management**: Fixed all path-related issues with absolute path handling
- **Thread safety**: Implemented proper thread-safe file detection and processing

**Test Results**: 
- ✅ All 6 integration tests pass (6/6)
- ✅ Multithreading provides correct results with performance improvements
- ✅ Perfect data integrity maintained across all test scenarios
- ✅ Docker integration works seamlessly with proper volume mounting