#!/usr/bin/env python3

import os
import sys
import tempfile
import shutil
import subprocess
import numpy as np
from biom import load_table
from biom.util import biom_open

# Add the bin directory to the path so we can import the script
sys.path.insert(0, '/home/jonsan/nf-reads-profiler/bin')

def compare_biom_tables(table1_path, table2_path, tolerance=1e-10):
    """Compare two BIOM tables for equivalence."""
    table1 = load_table(table1_path)
    table2 = load_table(table2_path)
    
    # Check dimensions
    if table1.shape != table2.shape:
        return False, f"Shape mismatch: {table1.shape} vs {table2.shape}"
    
    # Check sample IDs
    if set(table1.ids(axis='sample')) != set(table2.ids(axis='sample')):
        return False, "Sample IDs don't match"
    
    # Check observation IDs
    if set(table1.ids(axis='observation')) != set(table2.ids(axis='observation')):
        return False, "Observation IDs don't match"
    
    # Check data values (allowing for small numerical differences)
    # Need to ensure both tables have the same order
    table1_sorted = table1.sort_order(table1.ids(axis='observation'), axis='observation')
    table2_sorted = table2.sort_order(table2.ids(axis='observation'), axis='observation')
    
    table1_sorted = table1_sorted.sort_order(table1_sorted.ids(axis='sample'), axis='sample')
    table2_sorted = table2_sorted.sort_order(table2_sorted.ids(axis='sample'), axis='sample')
    
    data1 = table1_sorted.matrix_data.toarray()
    data2 = table2_sorted.matrix_data.toarray()
    
    if not np.allclose(data1, data2, atol=tolerance):
        return False, f"Data values don't match (max diff: {np.max(np.abs(data1 - data2))})"
    
    return True, "Tables are equivalent"

def create_larger_test_table(input_file, output_file, n_samples=200):
    """Create a larger test table by duplicating samples."""
    table = load_table(input_file)
    
    # Get original data
    original_data = table.matrix_data.toarray()
    original_samples = list(table.ids(axis='sample'))
    
    # Create new sample IDs
    new_samples = []
    new_data_cols = []
    
    for i in range(n_samples):
        # Cycle through original samples
        orig_idx = i % len(original_samples)
        new_samples.append(f"sample_{i:03d}")
        
        # Add some noise to make samples slightly different
        noise = np.random.normal(0, 0.1, original_data.shape[0])
        new_col = original_data[:, orig_idx] + noise
        new_col = np.maximum(new_col, 0)  # Ensure non-negative
        new_data_cols.append(new_col)
    
    # Create new data matrix
    new_data = np.column_stack(new_data_cols)
    
    # Create new table
    from biom import Table
    new_table = Table(new_data, table.ids(axis='observation'), new_samples)
    
    # Save to file
    with biom_open(output_file, 'w') as f:
        new_table.to_hdf5(f, "Large test table")
    
    print(f"Created large test table: {output_file}")
    print(f"Dimensions: {new_table.shape[0]} features x {new_table.shape[1]} samples")

def test_mock_command(test_data_dir):
    """Test the clustering script with a simple mock command."""
    
    with tempfile.TemporaryDirectory() as temp_dir:
        # Create a simple test script that copies input to output with a suffix
        test_script = os.path.join(temp_dir, "test_command.sh")
        with open(test_script, 'w') as f:
            f.write(f"""#!/bin/bash
# Simple test command that creates multiple output files
input_file="$1"
base_name=$(basename "$input_file" .biom)

# Create two output files in the temp directory
cp "$input_file" "{temp_dir}/${{base_name}}_output1.biom"
cp "$input_file" "{temp_dir}/${{base_name}}_output2.biom"

echo "Processed $input_file"
""")
        os.chmod(test_script, 0o755)
        
        # Test with a multi-sample table
        input_file = os.path.join(test_data_dir, "multi_sample_genefamilies.biom")
        
        # Run the clustering script
        cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            input_file,
            f"{test_script} {{input}}",
            "--max-samples", "1",  # Force splitting
            "--final-output-dir", temp_dir,
            "--command-output-location", temp_dir,
            "--output-regex-patterns", ".*_output1\\.biom$", ".*_output2\\.biom$",
            "--output-group-names", "group1", "group2",
            "--output-prefix", "test"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=temp_dir)
        
        print("Mock command test:")
        print(f"Return code: {result.returncode}")
        print(f"STDOUT:\n{result.stdout}")
        if result.stderr:
            print(f"STDERR:\n{result.stderr}")
        
        # Check if output files were created
        expected_files = ["test_group1.biom", "test_group2.biom"]
        for expected_file in expected_files:
            full_path = os.path.join(temp_dir, expected_file)
            if os.path.exists(full_path):
                print(f"✓ Created: {expected_file}")
                
                # Check if content matches original
                is_equal, msg = compare_biom_tables(input_file, full_path)
                if is_equal:
                    print(f"✓ Content matches original: {expected_file}")
                else:
                    print(f"✗ Content mismatch: {expected_file} - {msg}")
            else:
                print(f"✗ Missing: {expected_file}")
        
        return result.returncode == 0

def test_no_splitting(test_data_dir):
    """Test that the script works correctly when no splitting is needed."""
    
    with tempfile.TemporaryDirectory() as temp_dir:
        # Create a simple test script
        test_script = os.path.join(temp_dir, "copy_script.sh")
        with open(test_script, 'w') as f:
            f.write(f"""#!/bin/bash
input_file="$1"
base_name=$(basename "$input_file" .biom)
cp "$input_file" "{temp_dir}/${{base_name}}_result.biom"
""")
        os.chmod(test_script, 0o755)
        
        # Test with a small table that shouldn't need splitting
        input_file = os.path.join(test_data_dir, "multi_sample_genefamilies.biom")
        
        cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            input_file,
            f"{test_script} {{input}}",
            "--max-samples", "100",  # Large enough to not require splitting
            "--final-output-dir", temp_dir,
            "--command-output-location", temp_dir,
            "--output-regex-patterns", ".*_result\\.biom$",
            "--output-group-names", "result",
            "--output-prefix", "test"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=temp_dir)
        
        print("\nNo splitting test:")
        print(f"Return code: {result.returncode}")
        print(f"STDOUT:\n{result.stdout}")
        if result.stderr:
            print(f"STDERR:\n{result.stderr}")
        
        # Check if output file was created and matches original
        expected_file = os.path.join(temp_dir, "test_result.biom")
        if os.path.exists(expected_file):
            print("✓ Created: test_result.biom")
            
            is_equal, msg = compare_biom_tables(input_file, expected_file)
            if is_equal:
                print("✓ Content matches original")
            else:
                print(f"✗ Content mismatch: {msg}")
        else:
            print("✗ Missing: test_result.biom")
        
        return result.returncode == 0

def main():
    """Run all tests."""
    print("Testing safe_cluster_process.py with HUMAnN test data\n")
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    
    # Create a larger test table for splitting tests
    print("Creating larger test table...")
    input_file = os.path.join(test_data_dir, "multi_sample_genefamilies.biom")
    output_file = os.path.join(test_data_dir, "large_test_table.biom")
    create_larger_test_table(input_file, output_file, 150)
    
    # Run tests
    test_results = []
    
    print("\n" + "="*60)
    test_results.append(test_mock_command(test_data_dir))
    
    print("\n" + "="*60)
    test_results.append(test_no_splitting(test_data_dir))
    
    # Summary
    print("\n" + "="*60)
    print("TEST SUMMARY:")
    print(f"Mock command test: {'PASS' if test_results[0] else 'FAIL'}")
    print(f"No splitting test: {'PASS' if test_results[1] else 'FAIL'}")
    
    if all(test_results):
        print("\n✓ All tests passed!")
        return 0
    else:
        print("\n✗ Some tests failed!")
        return 1

if __name__ == "__main__":
    sys.exit(main())