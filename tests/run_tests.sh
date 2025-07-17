#!/bin/bash
#
# Wrapper script for running nf-reads-profiler integration tests
#
# Usage:
#   ./run_tests.sh                    # Run all tests
#   ./run_tests.sh --keep-temp        # Run all tests and keep temp files
#   ./run_tests.sh --test-filter real # Run only tests with 'real' in name
#

cd "$(dirname "$0")"
python3 run_integration_tests.py "$@"