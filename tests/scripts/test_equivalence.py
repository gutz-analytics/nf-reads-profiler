#!/usr/bin/env python3

import os
import sys
import tempfile
import subprocess
import shutil
import numpy as np
import pandas as pd
from biom import load_table
from biom.util import biom_open

def compare_biom_tables_exact(table1_path, table2_path):
    """
    Compare two BIOM tables for exact equivalence in content.
    Returns (is_equivalent, detailed_comparison_report)
    """
    try:
        table1 = load_table(table1_path)
        table2 = load_table(table2_path)
        
        report = []
        is_equivalent = True
        
        # Check dimensions
        if table1.shape != table2.shape:
            report.append(f"❌ Shape mismatch: {table1.shape} vs {table2.shape}")
            is_equivalent = False
        else:
            report.append(f"✅ Shape match: {table1.shape}")
        
        # Check sample IDs (sets should be identical)
        samples1 = set(table1.ids(axis='sample'))
        samples2 = set(table2.ids(axis='sample'))
        if samples1 != samples2:
            report.append(f"❌ Sample IDs differ")
            report.append(f"   Only in table1: {samples1 - samples2}")
            report.append(f"   Only in table2: {samples2 - samples1}")
            is_equivalent = False
        else:
            report.append(f"✅ Sample IDs match: {len(samples1)} samples")
        
        # Check observation IDs (sets should be identical)
        obs1 = set(table1.ids(axis='observation'))
        obs2 = set(table2.ids(axis='observation'))
        if obs1 != obs2:
            report.append(f"❌ Observation IDs differ")
            report.append(f"   Only in table1: {len(obs1 - obs2)} features")
            report.append(f"   Only in table2: {len(obs2 - obs1)} features")
            is_equivalent = False
        else:
            report.append(f"✅ Observation IDs match: {len(obs1)} features")
        
        # If basic structure matches, check data values
        if table1.shape == table2.shape and samples1 == samples2 and obs1 == obs2:
            # Convert to dataframes for easier comparison
            df1 = table1.to_dataframe().sort_index().sort_index(axis=1)
            df2 = table2.to_dataframe().sort_index().sort_index(axis=1)
            
            # Check for exact numerical equivalence
            if df1.equals(df2):
                report.append(f"✅ Data values are exactly equivalent")
            else:
                # Check if they're close (allowing for floating point errors)
                if np.allclose(df1.values, df2.values, rtol=1e-10, atol=1e-10):
                    report.append(f"✅ Data values are numerically equivalent (within tolerance)")
                else:
                    max_diff = np.max(np.abs(df1.values - df2.values))
                    report.append(f"❌ Data values differ (max difference: {max_diff})")
                    is_equivalent = False
        
        return is_equivalent, "\\n".join(report)
        
    except Exception as e:
        return False, f"❌ Error comparing tables: {str(e)}"


def test_humann_split_stratified_equivalence(test_data_dir, test_output_dir):
    """
    Test that safe_cluster_process.py produces identical results to humann_split_stratified_table
    """
    
    print("="*80)
    print("TESTING: humann_split_stratified_table EQUIVALENCE")
    print("="*80)
    
    # Use the dedicated test output directory
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    test_output_dir = os.path.join(project_root, "tests", "test_output")
    test_dir = os.path.join(test_output_dir, "test_temp_split")
    os.makedirs(test_dir, exist_ok=True)
    
    try:
        # Copy test file
        input_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
        temp_input = os.path.join(test_dir, "demo_genefamilies.biom")
        shutil.copy2(input_file, temp_input)
        
        # Verify file was copied
        print(f"File copied: {os.path.exists(temp_input)}")
        if os.path.exists(temp_input):
            print(f"File size: {os.path.getsize(temp_input)} bytes")
        
        # List all files in test directory
        print(f"Files in test directory: {os.listdir(test_dir)}")
        
        # Create output directories
        direct_output = os.path.join(test_dir, "direct_output")
        cluster_output = os.path.join(test_dir, "cluster_output")
        os.makedirs(direct_output, exist_ok=True)
        os.makedirs(cluster_output, exist_ok=True)
        
        print(f"Input file: {input_file}")
        print(f"Test directory: {test_dir}")
        
        # 1. Run direct humann_split_stratified_table
        print("\\n1. Running direct humann_split_stratified_table...")
        
        direct_cmd = [
            "humann_split_stratified_table", "-i", temp_input, "-o", direct_output
        ]
        
        print(f"Running: {' '.join(direct_cmd)}")
        direct_result = subprocess.run(direct_cmd, capture_output=True, text=True)
        
        print(f"Direct command return code: {direct_result.returncode}")
        if direct_result.stdout:
            print(f"STDOUT: {direct_result.stdout}")
        if direct_result.stderr:
            print(f"STDERR: {direct_result.stderr}")
        
        # Check direct output files
        direct_files = []
        if os.path.exists(direct_output):
            direct_files = [f for f in os.listdir(direct_output) if f.endswith('.biom')]
        
        print(f"Direct output files: {direct_files}")
        
        if direct_result.returncode != 0 or len(direct_files) < 2:
            print("❌ Direct command failed or produced insufficient output")
            return False
        
        # 2. Run with safe_cluster_process.py
        print("\\n2. Running safe_cluster_process.py...")
        
        cluster_cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            temp_input,
            "humann_split_stratified_table -i {input} -o .",
            "--max-samples", "2",  # Force splitting if multi-sample data is used
            "--final-output-dir", test_dir,
            "--command-output-location", ".",
            "--output-regex-patterns", ".*_stratified\\.biom$", ".*_unstratified\\.biom$",
            "--output-group-names", "stratified", "unstratified",
            "--output-prefix", "demo_cluster"
        ]
        
        print(f"Cluster command: {' '.join(cluster_cmd)}")
        cluster_result = subprocess.run(cluster_cmd, capture_output=True, text=True, cwd=test_dir)
        
        print(f"Cluster command return code: {cluster_result.returncode}")
        if cluster_result.stdout:
            print(f"STDOUT: {cluster_result.stdout}")
        if cluster_result.stderr:
            print(f"STDERR: {cluster_result.stderr}")
        
        # Check cluster output files
        cluster_files = [f for f in os.listdir(test_dir) if f.startswith("demo_cluster_") and f.endswith('.biom')]
        print(f"Cluster output files: {cluster_files}")
        
        if cluster_result.returncode != 0 or len(cluster_files) < 2:
            print("❌ Cluster command failed or produced insufficient output")
            return False
        
        # 3. Compare the results
        print("\\n3. Comparing results...")
        
        # Map direct files to cluster files
        comparisons = [
            ("demo_genefamilies_stratified.biom", "demo_cluster_stratified.biom", "Stratified"),
            ("demo_genefamilies_unstratified.biom", "demo_cluster_unstratified.biom", "Unstratified")
        ]
        
        all_equivalent = True
        
        for direct_file, cluster_file, description in comparisons:
            direct_path = os.path.join(direct_output, direct_file)
            cluster_path = os.path.join(test_dir, cluster_file)
            
            print(f"\\n--- Comparing {description} tables ---")
            
            if not os.path.exists(direct_path):
                print(f"❌ Missing direct output: {direct_file}")
                all_equivalent = False
                continue
                
            if not os.path.exists(cluster_path):
                print(f"❌ Missing cluster output: {cluster_file}")
                all_equivalent = False
                continue
            
            is_equiv, report = compare_biom_tables_exact(direct_path, cluster_path)
            print(report)
            
            if not is_equiv:
                all_equivalent = False
        
        return all_equivalent
    
    finally:
        # Clean up test directory
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir)

def test_humann_regroup_equivalence(test_data_dir, test_output_dir):
    """
    Test that safe_cluster_process.py produces identical results to humann_regroup_table
    """
    
    print("\\n" + "="*80)
    print("TESTING: humann_regroup_table EQUIVALENCE")
    print("="*80)
    
    # Use a subdirectory of the project for Docker compatibility
    # Docker has issues with /tmp directories, so use project directory
    project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    test_output_dir = os.path.join(project_root, "tests", "test_output")
    test_dir = os.path.join(test_output_dir, "test_temp_regroup")
    os.makedirs(test_dir, exist_ok=True)
    
    try:
        # Copy test file
        input_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
        temp_input = os.path.join(test_dir, "demo_genefamilies.biom")
        shutil.copy2(input_file, temp_input)
        
        print(f"Input file: {input_file}")
        print(f"Test directory: {test_dir}")
        
        # Test with uniref90_ko grouping
        group_type = "uniref90_ko"
        
        # 1. Run direct humann_regroup_table
        print(f"\\n1. Running direct humann_regroup_table with {group_type}...")
        direct_output = os.path.join(test_dir, "direct_ko.biom")
        
        direct_cmd = [
            "humann_regroup_table", "-i", temp_input, "-g", group_type, "-o", direct_output
        ]
        
        print(f"Running: {' '.join(direct_cmd)}")
        direct_result = subprocess.run(direct_cmd, capture_output=True, text=True)
        
        print(f"Direct command return code: {direct_result.returncode}")
        if direct_result.stdout:
            print(f"STDOUT: {direct_result.stdout}")
        if direct_result.stderr:
            print(f"STDERR: {direct_result.stderr}")
        
        if direct_result.returncode != 0 or not os.path.exists(direct_output):
            print("❌ Direct command failed or produced no output")
            return False
        
        # 2. Run with safe_cluster_process.py
        print("\\n2. Running safe_cluster_process.py...")
        
        cluster_cmd = [
            "/home/jonsan/nf-reads-profiler/bin/safe_cluster_process.py",
            temp_input,
            "humann_regroup_table -i {input} -g uniref90_ko -o {input}_ko.biom",
            "--max-samples", "2",  # Force splitting if multi-sample data is used
            "--final-output-dir", test_dir,
            "--command-output-location", ".",
            "--output-regex-patterns", ".*_ko.*\\.biom$",
            "--output-group-names", "ko",
            "--output-prefix", "demo_cluster"
        ]
        
        print(f"Cluster command: {' '.join(cluster_cmd)}")
        cluster_result = subprocess.run(cluster_cmd, capture_output=True, text=True, cwd=test_dir)
        
        print(f"Cluster command return code: {cluster_result.returncode}")
        if cluster_result.stdout:
            print(f"STDOUT: {cluster_result.stdout}")
        if cluster_result.stderr:
            print(f"STDERR: {cluster_result.stderr}")
        
        # Check cluster output
        cluster_output = os.path.join(test_dir, "demo_cluster_ko.biom")
        
        if cluster_result.returncode != 0 or not os.path.exists(cluster_output):
            print("❌ Cluster command failed or produced no output")
            return False
        
        # 3. Compare the results
        print("\\n3. Comparing results...")
        
        is_equiv, report = compare_biom_tables_exact(direct_output, cluster_output)
        print(report)
        
        return is_equiv
    
    finally:
        # Clean up test directory
        if os.path.exists(test_dir):
            shutil.rmtree(test_dir)

def main():
    """Run equivalence tests."""
    
    print("COMPREHENSIVE EQUIVALENCE TEST")
    print("Testing that safe_cluster_process.py produces identical results to bare HUMAnN commands")
    print("="*80)
    
    # Get test data directory from environment
    test_data_dir = os.environ.get('TEST_DATA_DIR', 'tests/data')
    test_output_dir = os.environ.get('TEST_OUTPUT_DIR', tempfile.mkdtemp())
    
    # Check if we have the necessary test files
    demo_file = os.path.join(test_data_dir, "demo_genefamilies.biom")
    if not os.path.exists(demo_file):
        print(f"❌ Error: {demo_file} not found")
        return 1
    
    # Run tests
    results = []
    
    # Test 1: humann_split_stratified_table
    try:
        result1 = test_humann_split_stratified_equivalence(test_data_dir, test_output_dir)
        results.append(("humann_split_stratified_table", result1))
    except Exception as e:
        print(f"❌ Test 1 failed with exception: {e}")
        results.append(("humann_split_stratified_table", False))
    
    # Test 2: humann_regroup_table
    try:
        result2 = test_humann_regroup_equivalence(test_data_dir, test_output_dir)
        results.append(("humann_regroup_table", result2))
    except Exception as e:
        print(f"❌ Test 2 failed with exception: {e}")
        results.append(("humann_regroup_table", False))
    
    # Summary
    print("\\n" + "="*80)
    print("EQUIVALENCE TEST SUMMARY")
    print("="*80)
    
    all_passed = True
    for test_name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{test_name}: {status}")
        if not passed:
            all_passed = False
    
    print("\\n" + "="*80)
    if all_passed:
        print("🎉 ALL TESTS PASSED!")
        print("safe_cluster_process.py produces IDENTICAL results to bare HUMAnN commands")
        print("The script maintains perfect data integrity while providing memory management")
    else:
        print("❌ SOME TESTS FAILED!")
        print("safe_cluster_process.py does not produce identical results")
        print("Further investigation needed before production use")
    
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())