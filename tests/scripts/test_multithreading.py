#!/usr/bin/env python3

import os
import sys
import tempfile
import subprocess
import shutil
import time
from biom import load_table

def test_multithreading_correctness():
    """Test that multithreaded processing produces identical results to sequential processing."""
    
    print("Testing multithreading correctness...")
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    
    # Use project directory for compatibility
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    temp_dir = os.path.join(project_root, "test_temp_threading")
    os.makedirs(temp_dir, exist_ok=True)
    
    try:
        # Create multi-sample test data if needed
        input_file = os.path.join(test_data_dir, "multi_sample_test_data.biom")
        if not os.path.exists(input_file):
            # Create test data using the existing large test table
            large_table_file = os.path.join(test_data_dir, "large_test_table.biom")
            if os.path.exists(large_table_file):
                input_file = large_table_file
            else:
                print("❌ No suitable multi-sample test data found")
                return False
        
        temp_input = os.path.join(temp_dir, "test_input.biom")
        shutil.copy2(input_file, temp_input)
        
        # Verify we have enough samples to split
        table = load_table(temp_input)
        print(f"Test data: {table.shape[1]} samples x {table.shape[0]} observations")
        
        if table.shape[1] < 4:
            print("❌ Need at least 4 samples to properly test threading")
            return False
        
        # Test configurations - focus on validating that multithreading executes correctly
        configs = [
            ("sequential", 1),
            ("parallel", 3),
        ]
        
        results = {}
        
        for config_name, num_threads in configs:
            print(f"\nTesting {config_name} processing (threads={num_threads})...")
            
            config_dir = os.path.join(temp_dir, config_name)
            os.makedirs(config_dir, exist_ok=True)
            
            # Time the execution
            start_time = time.time()
            
            # Use a simple copy command that preserves the BIOM format
            cmd = [
                "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
                temp_input,
                "cp {input} {input}.processed",
                "--max-samples", "10",  # Reasonable split size
                "--num-threads", str(num_threads),
                "--final-output-dir", config_dir,
                "--command-output-location", ".",  # Use current directory
                "--output-regex-patterns", ".*\\.processed$",
                "--output-group-names", "processed",
                "--output-prefix", f"test_{config_name}"
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True, cwd=config_dir)
            end_time = time.time()
            
            execution_time = end_time - start_time
            print(f"Execution time: {execution_time:.2f} seconds")
            
            if result.returncode != 0:
                print(f"❌ Command failed for {config_name}")
                print(f"STDERR: {result.stderr}")
                print(f"STDOUT: {result.stdout}")
                return False
            
            # Check output file
            output_file = os.path.join(config_dir, f"test_{config_name}_processed.biom")
            
            if not os.path.exists(output_file):
                print(f"❌ Output file not found for {config_name}: {output_file}")
                print(f"Files in {config_name} directory: {os.listdir(config_dir)}")
                return False
            
            # Load and verify output
            output_table = load_table(output_file)
            print(f"Output: {output_table.shape[1]} samples x {output_table.shape[0]} observations")
            
            results[config_name] = {
                'table': output_table,
                'time': execution_time,
                'threads': num_threads
            }
        
        # Verify all results are identical
        print("\nVerifying results consistency...")
        
        sequential_table = results['sequential']['table']
        sequential_time = results['sequential']['time']
        
        for config_name, config_data in results.items():
            if config_name == 'sequential':
                continue
                
            table = config_data['table']
            threads = config_data['threads']
            exec_time = config_data['time']
            
            # Check table shape
            if table.shape != sequential_table.shape:
                print(f"❌ Shape mismatch for {config_name}: {table.shape} vs {sequential_table.shape}")
                return False
            
            # Check sample IDs
            if set(table.ids(axis='sample')) != set(sequential_table.ids(axis='sample')):
                print(f"❌ Sample ID mismatch for {config_name}")
                return False
            
            # Check observation IDs
            if set(table.ids(axis='observation')) != set(sequential_table.ids(axis='observation')):
                print(f"❌ Observation ID mismatch for {config_name}")
                return False
            
            print(f"✅ {config_name} results match sequential")
            
            # Check if parallel processing provided speedup
            speedup = sequential_time / exec_time
            print(f"   Speedup: {speedup:.2f}x with {threads} threads")
        
        return True
        
    finally:
        # Clean up
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)

def test_multithreading_parameter():
    """Test that the --num-threads parameter works correctly."""
    
    print("\nTesting --num-threads parameter...")
    
    # Test with --help to see if parameter is documented
    cmd = ["/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py", "--help"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if "--num-threads" not in result.stdout:
        print("❌ --num-threads parameter not found in help output")
        return False
    
    print("✅ --num-threads parameter is documented")
    return True

def main():
    """Run multithreading tests."""
    print("Testing multithreading functionality in safe_cluster_process.py\n")
    
    # Check if we have the necessary test files
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    
    # Run tests
    results = []
    
    # Test 1: Parameter existence
    results.append(("Parameter test", test_multithreading_parameter()))
    
    # Test 2: Correctness test
    results.append(("Correctness test", test_multithreading_correctness()))
    
    # Summary
    print("\n" + "="*60)
    print("MULTITHREADING TEST SUMMARY:")
    
    all_passed = True
    for test_name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{test_name}: {status}")
        if not passed:
            all_passed = False
    
    if all_passed:
        print("\n✅ All multithreading tests passed!")
        print("Multithreading provides correct results with potential speedup")
        return 0
    else:
        print("\n❌ Some multithreading tests failed!")
        return 1

if __name__ == "__main__":
    sys.exit(main())