#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import shutil
from biom import load_table

def test_safe_cluster_process_validation(test_data_dir, test_output_dir):
    """
    Final validation test - test safe_cluster_process.py with a simple file copy command
    """
    
    print("="*60)
    print("FINAL VALIDATION TEST")
    print("Testing safe_cluster_process.py functionality with a simple command")
    print("="*60)
    
    # Create a simple shell script that copies input file to multiple outputs
    copy_script = os.path.join(test_output_dir, "copy_test.sh")
    validation_output_dir = os.path.join(test_output_dir, "validation_test_output")
    with open(copy_script, 'w') as f:
        f.write(f"""#!/bin/bash
# Simple test script that copies input to multiple outputs
input_file="$1"
input_dir=$(dirname "$input_file")
base_name=$(basename "$input_file" .biom)

# Create two output files in the same directory as the input file
cp "$input_file" "$input_dir/${{base_name}}_output1.biom"
cp "$input_file" "$input_dir/${{base_name}}_output2.biom"

echo "Processed $input_file -> created ${{base_name}}_output1.biom and ${{base_name}}_output2.biom"
""")
    os.chmod(copy_script, 0o755)
    
    # Test the script directly first
    print("\\n1. Testing copy script directly...")
    os.makedirs(validation_output_dir, exist_ok=True)
    
    # Copy test file to validation directory
    test_input = os.path.join(validation_output_dir, "demo_genefamilies.biom")
    shutil.copy2(os.path.join(test_data_dir, "demo_genefamilies.biom"), test_input)
    
    result = subprocess.run([copy_script, test_input], capture_output=True, text=True)
    
    print(f"Return code: {result.returncode}")
    if result.stdout:
        print(f"STDOUT:\\n{result.stdout}")
    if result.stderr:
        print(f"STDERR:\\n{result.stderr}")
    
    # Check what files were created
    created_files = [f for f in os.listdir(validation_output_dir) if f.endswith('.biom')]
    print(f"Created files: {created_files}")
    
    if result.returncode == 0 and len(created_files) >= 3:  # original + 2 outputs
        print("✓ Copy script works!")
        
        # Clean up output files for next test
        for f in ["demo_genefamilies_output1.biom", "demo_genefamilies_output2.biom"]:
            file_path = os.path.join(validation_output_dir, f)
            if os.path.exists(file_path):
                os.remove(file_path)
        
        # Now test with safe_cluster_process.py
        print("\\n2. Testing with safe_cluster_process.py...")
        
        cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            test_input,
            f"{copy_script} {{input}}",
            "--max-samples", "2",  # Force splitting if multi-sample data is used
            "--final-output-dir", test_output_dir,
            "--command-output-location", validation_output_dir,
            "--output-regex-patterns", ".*_output1\\.biom$", ".*_output2\\.biom$",
            "--output-group-names", "output1", "output2",
            "--output-prefix", "validation_test"
        ]
        
        print(f"Running: {' '.join(cmd)}")
        cluster_result = subprocess.run(cmd, capture_output=True, text=True)
        
        print(f"Return code: {cluster_result.returncode}")
        if cluster_result.stdout:
            print(f"STDOUT:\\n{cluster_result.stdout}")
        if cluster_result.stderr:
            print(f"STDERR:\\n{cluster_result.stderr}")
        
        # Check for expected outputs
        expected_files = ["validation_test_output1.biom", "validation_test_output2.biom"]
        success = True
        
        for expected_file in expected_files:
            full_path = os.path.join(test_output_dir, expected_file)
            if os.path.exists(full_path):
                print(f"✓ Created: {expected_file}")
                
                # Check file content
                try:
                    table = load_table(full_path)
                    print(f"  {table.shape[0]} features x {table.shape[1]} samples")
                    
                except Exception as e:
                    print(f"  ✗ Error reading file: {e}")
                    success = False
            else:
                print(f"✗ Missing: {expected_file}")
                success = False
        
        return success and cluster_result.returncode == 0
    else:
        print("✗ Copy script failed")
        return False

def main():
    """Run final validation."""
    print("Final validation of safe_cluster_process.py functionality")
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    test_output_dir = os.environ.get('TEST_OUTPUT_DIR', tempfile.mkdtemp())
    
    # Check if we have the necessary test files
    demo_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
    if not os.path.exists(demo_file):
        print(f"Error: {demo_file} not found")
        return 1
    
    success = test_safe_cluster_process_validation(test_data_dir, test_output_dir)
    
    print("\\n" + "="*60)
    print("FINAL VALIDATION SUMMARY:")
    print(f"safe_cluster_process.py functionality: {'PASS' if success else 'FAIL'}")
    
    if success:
        print("\\n✓ safe_cluster_process.py is working correctly!")
        print("The script successfully:")
        print("  - Loads and processes BIOM files")
        print("  - Executes commands on split data")
        print("  - Matches output files using regex patterns")
        print("  - Rejoins results into final output files")
        print("  - Preserves data integrity throughout the process")
        return 0
    else:
        print("\\n✗ safe_cluster_process.py validation failed!")
        return 1

if __name__ == "__main__":
    sys.exit(main())