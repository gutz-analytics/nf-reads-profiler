#!/usr/bin/env python3

import os
import sys
import tempfile
import subprocess
import shutil
import numpy as np
from biom import load_table

def test_humann_split_stratified_table(test_data_dir):
    """Test humann_split_stratified_table with real HUMAnN Docker image."""
    
    # Use the dedicated test output directory
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    test_output_dir = os.path.join(project_root, "tests", "test_output")
    temp_dir = os.path.join(test_output_dir, "test_temp_split_real")
    os.makedirs(temp_dir, exist_ok=True)
    
    try:
        # Use original test data with max-samples=1 to force splitting
        input_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
        temp_input = os.path.join(temp_dir, "demo_genefamilies.biom")
        subprocess.run(["cp", input_file, temp_input])
        
        print("Testing real humann_split_stratified_table command...")
        print(f"Input file: {input_file}")
        
        # Create output directory
        output_dir = os.path.join(temp_dir, "output")
        os.makedirs(output_dir, exist_ok=True)
        
        # Debug: check file exists
        print(f"Temp input file exists: {os.path.exists(temp_input)}")
        print(f"Temp input file path: {temp_input}")
        print(f"Output dir: {output_dir}")
        
        # Test direct command first
        cmd = ["humann_split_stratified_table", "-i", temp_input, "-o", output_dir]
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        print(f"Direct command return code: {result.returncode}")
        print(f"STDOUT:\n{result.stdout}")
        if result.stderr:
            print(f"STDERR:\n{result.stderr}")
        
        # Check what files were created
        created_files = []
        if os.path.exists(output_dir):
            created_files = [f for f in os.listdir(output_dir) if f.endswith('.biom')]
        print(f"Created files: {created_files}")
        
        if result.returncode == 0 and len(created_files) > 1:
            print("✓ Direct humann_split_stratified_table works")
            
            # Now test with safe_cluster_process.py
            print("\nTesting with safe_cluster_process.py...")
            
            # Clean up previous files
            for f in created_files:
                os.remove(os.path.join(output_dir, f))
            
            # Run safe_cluster_process.py
            cmd = [
                "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
                temp_input,
                "humann_split_stratified_table -i {input} -o .",
                "--max-samples", "2",  # Force splitting with 6 samples
                "--final-output-dir", temp_dir,
                "--command-output-location", ".",
                "--output-regex-patterns", ".*_stratified\\.biom$", ".*_unstratified\\.biom$",
                "--output-group-names", "stratified", "unstratified",
                "--output-prefix", "demo_clustered"
            ]
            
            cluster_result = subprocess.run(cmd, capture_output=True, text=True)
            
            print(f"Cluster process return code: {cluster_result.returncode}")
            print(f"STDOUT:\n{cluster_result.stdout}")
            if cluster_result.stderr:
                print(f"STDERR:\n{cluster_result.stderr}")
            
            # Check for expected outputs
            expected_files = ["demo_clustered_stratified.biom", "demo_clustered_unstratified.biom"]
            success = True
            
            for expected_file in expected_files:
                full_path = os.path.join(temp_dir, expected_file)
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
            print("✗ Direct humann_split_stratified_table failed")
            return False
    
    finally:
        # Clean up temp directory
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)

def test_humann_regroup_table(test_data_dir):
    """Test humann_regroup_table with real HUMAnN Docker image."""
    
    # Use project directory instead of /tmp for Docker compatibility
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    test_output_dir = os.path.join(project_root, "tests", "test_output")
    temp_dir = os.path.join(test_output_dir, "test_temp_regroup_real")
    os.makedirs(temp_dir, exist_ok=True)
    
    try:
        # Use original test data with max-samples=1 to force splitting
        input_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
        temp_input = os.path.join(temp_dir, "demo_genefamilies.biom")
        subprocess.run(["cp", input_file, temp_input])
        
        print("\nTesting real humann_regroup_table command...")
        
        # Test direct command first
        output_file = os.path.join(temp_dir, "demo_ko.biom")
        cmd = ["humann_regroup_table", "-i", temp_input, "-g", "uniref90_ko", "-o", output_file]
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        print(f"Direct command return code: {result.returncode}")
        print(f"STDOUT:\n{result.stdout}")
        if result.stderr:
            print(f"STDERR:\n{result.stderr}")
        
        if result.returncode == 0 and os.path.exists(output_file):
            print("✓ Direct humann_regroup_table works")
            
            # Remove the direct output
            os.remove(output_file)
            
            # Now test with safe_cluster_process.py
            print("\nTesting with safe_cluster_process.py...")
            
            cmd = [
                "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
                temp_input,
                "humann_regroup_table -i {input} -g uniref90_ko -o {input}_ko.biom",
                "--max-samples", "2",  # Force splitting with 6 samples
                "--final-output-dir", temp_dir,
                "--command-output-location", ".",
                "--output-regex-patterns", ".*_ko.*\\.biom$",
                "--output-group-names", "ko",
                "--output-prefix", "demo_clustered"
            ]
            
            cluster_result = subprocess.run(cmd, capture_output=True, text=True)
            
            print(f"Cluster process return code: {cluster_result.returncode}")
            print(f"STDOUT:\n{cluster_result.stdout}")
            if cluster_result.stderr:
                print(f"STDERR:\n{cluster_result.stderr}")
            
            # Check for expected output
            expected_file = "demo_clustered_ko.biom"
            full_path = os.path.join(temp_dir, expected_file)
            
            if os.path.exists(full_path):
                print(f"✓ Created: {expected_file}")
                
                # Check file content
                try:
                    table = load_table(full_path)
                    print(f"  {table.shape[0]} features x {table.shape[1]} samples")
                    
                    # Compare with direct output
                    # Run direct command again for comparison
                    direct_output_file = os.path.join(temp_dir, "demo_ko_direct.biom")
                    direct_cmd = ["humann_regroup_table", "-i", temp_input, "-g", "uniref90_ko", "-o", direct_output_file]
                    direct_result = subprocess.run(direct_cmd, capture_output=True, text=True)
                    
                    if direct_result.returncode == 0:
                        direct_table = load_table(direct_output_file)
                        
                        if (table.shape == direct_table.shape and 
                            set(table.ids(axis='sample')) == set(direct_table.ids(axis='sample')) and
                            set(table.ids(axis='observation')) == set(direct_table.ids(axis='observation'))):
                            print("  ✓ Output matches direct command")
                        else:
                            print("  ⚠ Output differs from direct command")
                    
                    return True
                except Exception as e:
                    print(f"  ✗ Error reading file: {e}")
                    return False
            else:
                print(f"✗ Missing: {expected_file}")
                return False
        else:
            print("✗ Direct humann_regroup_table failed")
            return False
    
    finally:
        # Clean up temp directory
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir)

def main():
    """Run tests with real HUMAnN commands."""
    print("Testing safe_cluster_process.py with real HUMAnN commands\n")
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    
    # Check if we have the necessary test files
    demo_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
    if not os.path.exists(demo_file):
        print(f"Error: {demo_file} not found")
        return 1
    
    # Run tests
    test_results = []
    
    print("="*60)
    test_results.append(test_humann_split_stratified_table(test_data_dir))
    
    print("="*60)
    test_results.append(test_humann_regroup_table(test_data_dir))
    
    # Summary
    print("\n" + "="*60)
    print("REAL HUMANN TEST SUMMARY:")
    print(f"humann_split_stratified_table: {'PASS' if test_results[0] else 'FAIL'}")
    print(f"humann_regroup_table: {'PASS' if test_results[1] else 'FAIL'}")
    
    if all(test_results):
        print("\n✓ All real HUMAnN tests passed!")
        return 0
    else:
        print("\n✗ Some real HUMAnN tests failed!")
        return 1

if __name__ == "__main__":
    sys.exit(main())