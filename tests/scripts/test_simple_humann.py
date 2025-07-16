#!/usr/bin/env python3

import os
import subprocess
import sys
from biom import load_table

def test_humann_split_with_safe_cluster(test_data_dir):
    """Test safe_cluster_process.py with humann_split_stratified_table."""
    
    # Use tests/test_output directory for all test outputs
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    test_output_dir = os.path.join(project_root, "tests", "test_output")
    os.makedirs(test_output_dir, exist_ok=True)
    
    # Create specific output directory for this test
    output_dir = os.path.join(test_output_dir, "simple_humann_test_output")
    os.makedirs(output_dir, exist_ok=True)
    
    print("="*60)
    print("Testing humann_split_stratified_table with safe_cluster_process.py")
    print("="*60)
    
    # First, test direct command
    print("\n1. Testing direct humann_split_stratified_table command...")
    input_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
    cmd = ["humann_split_stratified_table", "-i", input_file, "-o", output_dir]
    
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    print(f"Return code: {result.returncode}")
    if result.stdout:
        print(f"STDOUT:\n{result.stdout}")
    if result.stderr:
        print(f"STDERR:\n{result.stderr}")
    
    # Check what files were created
    created_files = []
    if os.path.exists(output_dir):
        created_files = [f for f in os.listdir(output_dir) if f.endswith('.biom')]
    
    print(f"Created files: {created_files}")
    
    if result.returncode == 0 and len(created_files) >= 2:
        print("✓ Direct command works!")
        
        # Clean up for next test
        for f in created_files:
            os.remove(os.path.join(output_dir, f))
        
        # Now test with safe_cluster_process.py
        print("\n2. Testing with safe_cluster_process.py...")
        
        cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            os.path.abspath(os.path.join(test_data_dir, "demo_genefamilies.biom")),
            "humann_split_stratified_table -i {input} -o .",
            "--max-samples", "2",  # Force splitting if multi-sample data is used
            "--final-output-dir", test_output_dir,
            "--command-output-location", ".",
            "--output-regex-patterns", ".*_stratified\\.biom$", ".*_unstratified\\.biom$",
            "--output-group-names", "stratified", "unstratified",
            "--output-prefix", "demo_safe"
        ]
        
        print(f"Running: {' '.join(cmd)}")
        cluster_result = subprocess.run(cmd, capture_output=True, text=True)
        
        print(f"Return code: {cluster_result.returncode}")
        if cluster_result.stdout:
            print(f"STDOUT:\n{cluster_result.stdout}")
        if cluster_result.stderr:
            print(f"STDERR:\n{cluster_result.stderr}")
        
        # Check for expected outputs
        expected_files = ["demo_safe_stratified.biom", "demo_safe_unstratified.biom"]
        success = True
        
        for expected_file in expected_files:
            full_path = os.path.join(test_output_dir, expected_file)
            if os.path.exists(full_path):
                print(f"✓ Created: {expected_file}")
                
                # Check file content
                try:
                    table = load_table(full_path)
                    print(f"  {table.shape[0]} features x {table.shape[1]} samples")
                    
                    # Check for stratified vs unstratified features
                    feature_ids = list(table.ids(axis='observation'))
                    stratified_count = sum(1 for f in feature_ids if '|' in f)
                    unstratified_count = len(feature_ids) - stratified_count
                    
                    if "stratified" in expected_file:
                        if stratified_count > 0:
                            print(f"  ✓ Contains {stratified_count} stratified features")
                        else:
                            print(f"  ⚠ Warning: No stratified features found")
                    elif "unstratified" in expected_file:
                        if unstratified_count > 0:
                            print(f"  ✓ Contains {unstratified_count} unstratified features")
                        else:
                            print(f"  ⚠ Warning: No unstratified features found")
                    
                except Exception as e:
                    print(f"  ✗ Error reading file: {e}")
                    success = False
            else:
                print(f"✗ Missing: {expected_file}")
                success = False
        
        return success and cluster_result.returncode == 0
    else:
        print("✗ Direct command failed")
        return False

def main():
    """Run the test."""
    print("Testing safe_cluster_process.py with real HUMAnN commands")
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    
    # Check if we have the necessary test files
    demo_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
    if not os.path.exists(demo_file):
        print(f"Error: {demo_file} not found")
        return 1
    
    success = test_humann_split_with_safe_cluster(test_data_dir)
    
    print("\n" + "="*60)
    print("TEST SUMMARY:")
    print(f"HUMAnN split with safe_cluster_process.py: {'PASS' if success else 'FAIL'}")
    
    if success:
        print("\n✓ Test passed!")
        return 0
    else:
        print("\n✗ Test failed!")
        return 1

if __name__ == "__main__":
    sys.exit(main())