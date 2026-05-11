# Testing Documentation

This directory contains comprehensive tests for the nf-reads-profiler pipeline, including both workflow-level integration tests and script-level unit tests.

## Overview

The testing framework consists of two main components:

1. **Workflow Integration Tests** (`main.nf.test`) - Test the complete Nextflow pipeline
2. **Script Integration Tests** (`scripts/test_*.py`) - Test individual bioinformatics scripts and components

## Test Data

### Test Data Location
- **Primary test data**: `tests/data/` - Contains BIOM files for script testing
- **Pipeline test data**: `assets/test_data/` - Contains FASTQ files for pipeline testing
- **Test databases**: `assets/test_dbs/` - Contains minimal databases for testing

### Test Data Files
- `demo_genefamilies.biom` - Small BIOM file from HUMAnN demo data
- `genefamilies.biom` - Additional BIOM test file
- `multi_sample_genefamilies.biom` - Multi-sample BIOM file for testing
- `large_test_table.biom` - Generated during tests for splitting functionality

## 1. Workflow Integration Tests (nf-test)

### Purpose
Tests the complete Nextflow pipeline end-to-end, including:
- Data input validation
- Process execution and chaining
- Output file generation
- Multiple input types (local files, SRA accessions)
- Error handling and filtering

### Location
- **Test file**: `tests/main.nf.test`
- **Configuration**: `conf/test.config`

### Test Cases

#### 1. Local Files Test (`local`)
```bash
nf-test test tests/main.nf.test --tag local
```
- Tests paired-end analysis with local FASTQ files
- Validates taxonomic and functional profiling outputs
- Checks combined output generation for multiple studies

#### 2. Read Filtering Test (`read_filter`)
```bash
nf-test test tests/main.nf.test --tag read_filter
```
- Tests minimum read count filtering
- Validates that samples below threshold are excluded
- Ensures read count files are generated for all samples

#### 3. SRA Download Test (`SRA`)
```bash
nf-test test tests/main.nf.test --tag SRA
```
- Tests SRA accession download and processing
- Validates FASTERQ_DUMP functionality
- Ensures proper handling of downloaded data

#### 4. Mixed Input Test (`"SRA and local"`)
```bash
nf-test test tests/main.nf.test --tag "SRA and local"
```
- Tests simultaneous processing of local files and SRA accessions
- Validates proper data routing and processing

#### 5. Mixed Read Types Test (`"SRA and local combined ended"`)
```bash
nf-test test tests/main.nf.test --tag "SRA and local combined ended"
```
- Tests handling of both single-end and paired-end reads
- Validates proper detection and processing of different read types

#### 6. SRA Three Files Test (`sra-three-files`)
```bash
nf-test test tests/main.nf.test --tag sra-three-files
```
- Tests SRA samples that produce three output files
- Validates proper file handling and pairing

### Running Workflow Tests

#### All Tests
```bash
nf-test test
```

#### Specific Test
```bash
nf-test test tests/main.nf.test --tag <tag_name>
```

#### With Verbose Output
```bash
nf-test test --verbose
```

### Test Configuration

The workflow tests use `conf/test.config` which provides:
- Minimal resource requirements for fast testing
- Docker containerization
- Test database paths
- Reduced data size (`nreads = 10000`)
- Bypass options for faster execution

## 2. Script Integration Tests (Python)

### Purpose
Tests individual scripts and components in isolation:
- `safe_cluster_process.py` functionality
- HUMAnN Docker container integration
- BIOM file processing and validation
- Memory management and data splitting
- Output file generation and validation

### Location
- **Test runner**: `run_integration_tests.py`
- **Shell wrapper**: `run_tests.sh`
- **Test scripts**: `scripts/test_*.py`

### Test Scripts

#### 1. `test_safe_cluster_process.py`
- Tests basic functionality of the memory management script
- Validates BIOM file splitting and rejoining
- Tests mock command execution

#### 2. `test_simple_humann.py`
- Tests basic HUMAnN Docker container execution
- Validates `humann_split_stratified_table` functionality
- Tests integration with `safe_cluster_process.py`

#### 3. `test_equivalence.py`
- **Critical test**: Validates that `safe_cluster_process.py` produces identical results to direct HUMAnN commands
- Tests both `humann_split_stratified_table` and `humann_regroup_table`
- Performs exact numerical comparison of BIOM files
- Ensures data integrity is maintained through processing

#### 4. `test_real_humann.py`
- Tests real HUMAnN commands in Docker containers
- Validates both splitting and regrouping functionality
- Tests Docker volume mounting and file access

#### 5. `test_final_validation.py`
- Final validation of `safe_cluster_process.py` functionality
- Tests regex pattern matching and output grouping
- Validates file joining and output generation

### Running Script Tests

#### All Tests
```bash
cd tests
./run_tests.sh
```

#### Specific Test
```bash
cd tests
./run_tests.sh --test-filter <test_name>
```

#### Keep Temporary Files
```bash
cd tests
./run_tests.sh --keep-temp
```

#### Direct Python Execution
```bash
cd tests
python3 run_integration_tests.py
```

### Test Environment

The script tests use environment variables for configuration:
- `TEST_DATA_DIR` - Path to test data directory
- `TEST_OUTPUT_DIR` - Path for temporary test outputs
- `PYTHONPATH` - Python module search path

## Prerequisites

### Software Requirements
- **Nextflow** (≥22.10.0)
- **nf-test** (≥0.8.0)
- **Docker** (for containerized execution)
- **Python 3** (≥3.8)

### Python Dependencies
```bash
pip install biom-format numpy pandas h5py
```

### Docker Images
The tests require these Docker images:
- `gutzcontainers.azurecr.io/humann:4.0.0a1-1`
- `quay.io/biocontainers/metaphlan:4.1.0--pyhca03a8a_0`
- `quay.io/biocontainers/fastp:0.23.4--hadf994f_1`

## Test Data Setup

### Generating Test Data
Some test data is generated during test execution:
- `large_test_table.biom` - Created by `test_safe_cluster_process.py`
- Temporary split files - Created and cleaned up during testing

### Test Database Setup
For workflow tests, minimal test databases are required in `assets/test_dbs/`:
- MetaPhlAn4 test database
- HUMAnN3 ChocoPhlAn database (minimal)
- HUMAnN3 UniRef database (minimal)
- Utility mapping files

## Continuous Integration

### Running All Tests
```bash
# Run workflow tests
nf-test test

# Run script tests
cd tests && ./run_tests.sh

# Quick syntax check
nextflow run main.nf --help
```

### Test Success Criteria
- **Workflow tests**: All assertions pass, expected output files exist
- **Script tests**: All 5 tests pass (5/5), exact numerical equivalence verified
- **Integration**: `safe_cluster_process.py` produces identical results to direct commands

## Troubleshooting

### Common Issues

#### Docker Permission Errors
```bash
# Ensure Docker daemon is running
sudo systemctl start docker

# Add user to docker group
sudo usermod -aG docker $USER
```

#### Memory Issues
```bash
# Increase Docker memory limits
# Edit Docker Desktop settings or daemon.json
```

#### Test Data Missing
```bash
# Ensure test data exists
ls -la tests/data/
ls -la assets/test_data/
```

#### nf-test Installation
```bash
# Install nf-test
curl -s https://get.nf-test.com | bash
```

### Debugging

#### Verbose Test Output
```bash
nf-test test --verbose
```

#### Keep Test Files
```bash
cd tests && ./run_tests.sh --keep-temp
```

#### Manual Test Execution
```bash
cd tests/scripts
python3 test_equivalence.py
```

## Test Development

### Adding New Tests

#### Workflow Tests
1. Add new test case to `main.nf.test`
2. Create appropriate test data in `assets/test_data/`
3. Update `conf/test.config` if needed
4. Test with `nf-test test --tag <new_tag>`

#### Script Tests
1. Create new `test_*.py` file in `scripts/`
2. Follow existing test patterns
3. Use environment variables for paths
4. Ensure cleanup in `finally` blocks
5. Test with `./run_tests.sh --test-filter <new_test>`

### Test Best Practices
- Use minimal test data for speed
- Clean up temporary files
- Use absolute paths in tests
- Validate both success and failure cases
- Document expected behavior
- Use descriptive test names and tags

## Performance

### Test Execution Times
- **Workflow tests**: 10-30 minutes (depends on Docker pulls)
- **Script tests**: 2-5 minutes
- **Individual test**: 30 seconds - 2 minutes

### Optimization Tips
- Use Docker image caching
- Minimize test data size
- Run tests in parallel where possible
- Use `--keep-temp` only for debugging