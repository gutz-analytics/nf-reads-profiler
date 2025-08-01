# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Status: HUMAnN Workflow Successfully Deployed and Validated ✅

**Date**: July 29, 2025  
**Branch**: `simplified_humann_tables`

### Recently Completed Work

**✅ MAJOR WORKFLOW SIMPLIFICATION AND DEPLOYMENT COMPLETED**

We successfully simplified, deployed, and validated the HUMAnN processing workflow with improved memory efficiency, maintainability, and correct file organization.

**FINAL WORKFLOW:**
```
HUMAnN TSV → combine → split stratified → convert to biom → regroup_genefamilies (optional)
```

### Completed Changes

1. **✅ Core Workflow Processes:**
   - `split_stratified_tables`: Works with TSV files directly, outputs stratified/unstratified separately
   - `convert_tables_to_biom`: Enhanced with proper stratification metadata and file organization
   - `regroup_genefamilies`: Dedicated process for optional regrouping of genefamilies biom files only
   - **REMOVED** `process_humann_tables`: Complex monolithic process eliminated

2. **✅ Workflow Logic and Channel Routing:**
   - Updated `main.nf` with proper channel mixing and metadata flow
   - Fixed stratification metadata propagation (`'stratified'`/`'unstratified'` for functional tables)
   - Taxonomy tables correctly handled without stratification metadata
   - Proper error handling for multi-channel outputs

3. **✅ File Organization and Publishing:**
   - Fixed publishDir patterns for all biom file types
   - Proper directory structure in `combined_bioms/`:
     - `genefamilies/` - stratified and unstratified biom files
     - `pathabundance/` - stratified and unstratified biom files  
     - `reactions/` - stratified and unstratified biom files
     - `humann_taxonomy/` - combined taxonomy biom files (no stratification)
     - `metaphlan/` - MetaPhlAn taxonomy biom files
     - `regrouped/` - regrouped genefamilies biom files (KO and reactions)

4. **✅ Database Compatibility Updates:**
   - Downloaded HUMAnN4 compatible ChocoPhlAn demo database
   - Updated test configuration for HUMAnN4 containers
   - Bypassed translated search for database compatibility
   - Increased memory allocation to 8GB for test processes

### Production Validation Status

- ✅ **Workflow Execution**: Successfully completed on real dataset (3 studies, multiple samples)
- ✅ **File Organization**: All biom files correctly organized in appropriate subdirectories  
- ✅ **Stratification Logic**: Proper stratified vs unstratified file generation
- ✅ **Metadata Flow**: Correct filename generation with stratification info
- ✅ **Output Quality**: Biologically sensible results with expected feature abundances
- ✅ **Performance Metrics**: UNMAPPED read percentages within normal ranges (40-85%)

### Current Output Structure Validation

**Sample Output Analysis:**
- **Derosa_2022**: 40.57% UNMAPPED reads (good quality)
- **Peters_2019**: 80.48% UNMAPPED reads (normal for complex samples)  
- **Routy_2018**: 84.39% UNMAPPED reads (normal for complex samples)

**Feature Analysis Completed:**
- Top abundant features identified across all biom file types
- Taxonomic consistency verified between MetaPhlAn and HUMAnN taxonomy
- Functional stratification working correctly with species-level assignments
- Regrouping producing expected KO and reaction classifications

### Critical Bug Fixes Applied

**🐛 FIXED: Multi-channel Output Error**
- **Issue**: `Multi-channel output cannot be applied to operator mix` error
- **Root Cause**: Incorrect channel mixing syntax with multi-output processes  
- **Solution**: Properly accessed specific output channels (`stratified_tables`, `unstratified_tables`) and applied metadata transformations in workflow

**🐛 FIXED: File Organization Issues**
- **Issue**: Empty `combined_bioms` subdirectories and `_null` in filenames
- **Root Cause**: Missing stratification metadata propagation from splitting process
- **Solution**: Added stratification metadata (`'stratified'`/`'unstratified'`) via `.map()` operations in main workflow

**🐛 FIXED: PublishDir Pattern Matching**
- **Issue**: Biom files not appearing in correct subdirectories
- **Root Cause**: PublishDir patterns didn't match actual filename formats
- **Solution**: Updated patterns to handle both stratified (`*_type_*.biom`) and unstratified (`*_type.biom`) formats

**🐛 FIXED: HUMAnN4 Database Compatibility**  
- **Issue**: Database version conflicts with HUMAnN4 containers
- **Root Cause**: Test databases incompatible with newer HUMAnN4 requirements
- **Solution**: Downloaded compatible ChocoPhlAn v4 demo database and bypassed translated search

### Key Benefits

- **Memory Efficiency**: Split stratified on TSV files (smaller) before biom conversion
- **Cleaner Logic**: Separate concerns - splitting → conversion → regrouping
- **Selective Processing**: Only regroup genefamilies (most useful tables)
- **Better Maintainability**: Simpler, more focused processes

## Overview

This is a Nextflow pipeline for metagenomic read profiling using MetaPhlAn4 and HUMAnN3, with optional MEDI (food microbiome) quantification. The pipeline is based on the original YAMP repository but has been modified for Azure Batch execution with containerized bioinformatics tools.

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

**Azure Batch with MEDI quantification:**
```bash
nextflow run main.nf -profile azure --input samplesheet.csv --project <project_name> --outdir <output_path> --enable_medi
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

The pipeline is organized into four main process groups:

1. **Data Handling (`modules/data_handling.nf`)**
   - `AWS_DOWNLOAD`: Downloads SRA files from S3
   - `FASTERQ_DUMP`: Converts SRA files to FASTQ format

2. **Community Characterization (`modules/community_characterisation.nf`)**
   - `profile_taxa`: Taxonomic profiling using MetaPhlAn4
   - `profile_function`: Functional profiling using HUMAnN3
   - `combine_humann_tables`: Combines HUMAnN3 output tables
   - `combine_metaphlan_tables`: Combines MetaPhlAn4 output tables

3. **MEDI Quantification (`subworkflows/quant.nf`)**
   - `MEDI_QUANT`: Food microbiome quantification subworkflow
   - `kraken`: Kraken2 taxonomic classification
   - `architeuthis_filter`: Architeuthis mapping filter
   - `kraken_report`: Kraken2 report generation
   - `count_taxa`: Bracken abundance estimation
   - `quantify`: Food abundance quantification

4. **House Keeping (`modules/house_keeping.nf`)**
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
- MEDI: `params.docker_container_medi` (specified in configuration)

### Database Requirements

**MetaPhlAn4 databases:**
- Located at `/dbs/metagenometest/metagenome-dbs/metaphlan/metaphlan4/vJun23`
- Index: `mpa_vJun23_CHOCOPhlAnSGB_202307`

**HUMAnN3 databases:**
- ChocoPhlAn: `/dbs/metagenometest/metagenome-dbs/humann/3.0/chocophlan/`
- UniRef90: `/dbs/metagenometest/metagenome-dbs/humann/3.0/uniref/`
- Utility mapping: `/dbs/metagenometest/metagenome-dbs/humann/3.0/utility_mapping/`

**MEDI databases:**
- Kraken2/Bracken database: `params.medi_db_path`
- Foods definition file: `params.medi_foods_file`
- Food contents mapping: `params.medi_food_contents_file`

### Key Parameters

**Core Pipeline:**
- `skipHumann`: Skip functional profiling (default: false)
- `singleEnd`: Single-end reads mode (default: false)
- `nreads`: Limit number of reads processed (default: 33333333)
- `minreads`: Minimum reads required per sample (default: 100000)
- `annotation`: Enable functional annotation (default: true)

**MEDI Quantification:**
- `enable_medi`: Enable MEDI workflow (default: false)
- `confidence`: Kraken2 confidence threshold (default: 0.3)
- `consistency`: Architeuthis filter consistency threshold (default: 0.95)
- `entropy`: Architeuthis filter entropy threshold (default: 0.1)
- `multiplicity`: Architeuthis filter multiplicity threshold (default: 4)
- `read_length`: Read length for Bracken (default: 150)
- `threshold`: Bracken abundance threshold (default: 10)
- `batchsize`: Batch size for Kraken2 processing (default: 400)
- `mapping`: Enable mapping summary generation (default: false)

### Output Structure

```
outdir/
├── project/
│   ├── study/
│   │   ├── taxa/           # MetaPhlAn4 taxonomic profiles
│   │   ├── function/       # HUMAnN3 functional profiles
│   │   ├── medi/           # MEDI quantification results (if enabled)
│   │   │   ├── kraken2/    # Kraken2 taxonomic classification
│   │   │   ├── bracken/    # Bracken abundance estimation
│   │   │   ├── merged/     # Merged taxonomy tables
│   │   │   ├── architeuthis/ # Mapping summaries (if enabled)
│   │   │   ├── food_abundance.csv
│   │   │   ├── food_content.csv
│   │   │   ├── D_counts.csv
│   │   │   ├── G_counts.csv
│   │   │   ├── S_counts.csv
│   │   │   └── multiqc_report.html
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

## MEDI Workflow Integration

### Overview

The MEDI (Metagenomic Estimation of Dietary Intake) workflow has been integrated as a subworkflow (`subworkflows/quant.nf`) for food microbiome quantification. This workflow processes cleaned reads through Kraken2 taxonomic classification, Architeuthis filtering, Bracken abundance estimation, and final food quantification.

### Integration Status

🚧 **IN DEVELOPMENT** - The MEDI workflow has been successfully integrated into the pipeline structure but requires testing before production use.

### Completed Integration Tasks

- ✅ Subworkflow structure implemented (`subworkflows/quant.nf`)
- ✅ Main workflow integration with conditional execution
- ✅ Parameter configuration added to `nextflow.config`
- ✅ Profile-based configuration (test/azure)
- ✅ Workflow syntax validation
- ✅ Preview mode execution

### Pending Tasks

- 🔄 **Full workflow testing** - End-to-end testing with real data
- 🔄 **Container validation** - Verify MEDI container accessibility
- 🔄 **Database validation** - Confirm database paths and formats
- 🔄 **Resource optimization** - Tune memory and CPU requirements
- 🔄 **Error handling** - Test failure scenarios and recovery

### Usage (Testing Phase)

**Enable MEDI workflow:**
```bash
nextflow run main.nf --enable_medi --medi_db_path /path/to/db --medi_foods_file foods.csv --medi_food_contents_file contents.csv
```

**Required Parameters:**
- `medi_db_path`: Path to Kraken2/Bracken database
- `medi_foods_file`: Foods definition file
- `medi_food_contents_file`: Food contents mapping file

### Expected Output Files

- `food_abundance.csv`: Food abundance matrix
- `food_content.csv`: Food content matrix
- `D_counts.csv`, `G_counts.csv`, `S_counts.csv`: Taxonomy counts by level
- `multiqc_report.html`: Quality control report
- `mappings.csv`: Mapping summaries (if enabled)