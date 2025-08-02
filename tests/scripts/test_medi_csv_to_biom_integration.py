#!/usr/bin/env python3
"""
Integration tests for medi_csv_to_biom.py script.

Tests the complete script execution with file I/O.
"""

import os
import sys
import tempfile
import shutil
import subprocess
import pandas as pd
from pathlib import Path
from biom import load_table

def get_test_data_dir():
    """Get the test data directory."""
    return Path(os.environ.get('TEST_DATA_DIR', Path(__file__).parent.parent / 'data'))

def get_test_output_dir():
    """Get the temporary test output directory."""
    return Path(os.environ.get('TEST_OUTPUT_DIR', Path(__file__).parent.parent / 'test_output'))

def get_script_path():
    """Get the path to the medi_csv_to_biom.py script."""
    return Path(__file__).parent.parent.parent / 'bin' / 'medi_csv_to_biom.py'

def test_food_abundance_conversion():
    """Test conversion of food_abundance.csv to BIOM format."""
    print("Testing food abundance CSV to BIOM conversion...")
    
    test_data_dir = get_test_data_dir()
    test_output_dir = get_test_output_dir()
    script_path = get_script_path()
    
    input_csv = test_data_dir / 'test_food_abundance.csv'
    output_biom = test_output_dir / 'test_food_abundance.biom'
    
    # Ensure input file exists
    if not input_csv.exists():
        raise FileNotFoundError(f"Test input file not found: {input_csv}")
    
    # Run the conversion script
    cmd = [
        'python', str(script_path),
        str(input_csv),
        str(output_biom),
        '--type', 'abundance'
    ]
    
    print(f"Running command: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"Command failed with return code {result.returncode}")
        print(f"STDOUT: {result.stdout}")
        print(f"STDERR: {result.stderr}")
        return False
    
    # Verify output file was created
    if not output_biom.exists():
        print(f"Output BIOM file was not created: {output_biom}")
        return False
    
    # Load and validate the BIOM table
    try:
        biom_table = load_table(str(output_biom))
        
        # Validate basic structure
        print(f"BIOM table shape: {biom_table.shape}")
        print(f"Sample IDs: {list(biom_table.ids())}")
        print(f"Observation IDs: {list(biom_table.ids(axis='observation'))}")
        
        # Expected: 2 samples (sample1, sample2), 3 food items (83, 307, 334)
        expected_samples = {'sample1', 'sample2'}
        expected_observations = {'83', '307', '334'}
        
        actual_samples = set(biom_table.ids())
        actual_observations = set(biom_table.ids(axis='observation'))
        
        if actual_samples != expected_samples:
            print(f"Sample ID mismatch. Expected: {expected_samples}, Got: {actual_samples}")
            return False
        
        if actual_observations != expected_observations:
            print(f"Observation ID mismatch. Expected: {expected_observations}, Got: {actual_observations}")
            return False
        
        # Check metadata
        sample_metadata = biom_table.metadata(axis='sample')
        obs_metadata = biom_table.metadata(axis='observation')
        
        if sample_metadata is None:
            print("Sample metadata is missing")
            return False
        
        if obs_metadata is None:
            print("Observation metadata is missing")
            return False
        
        # Check specific metadata fields
        first_obs_metadata = obs_metadata[0]
        if 'taxonomy' not in first_obs_metadata:
            print("Taxonomy metadata is missing from observations")
            return False
        
        print("✅ Food abundance conversion test passed")
        return True
        
    except Exception as e:
        print(f"Error loading BIOM file: {e}")
        return False

def test_food_content_conversion():
    """Test conversion of food_content.csv to BIOM format."""
    print("Testing food content CSV to BIOM conversion...")
    
    test_data_dir = get_test_data_dir()
    test_output_dir = get_test_output_dir()
    script_path = get_script_path()
    
    input_csv = test_data_dir / 'test_food_content.csv'
    output_biom = test_output_dir / 'test_food_content.biom'
    
    # Ensure input file exists
    if not input_csv.exists():
        raise FileNotFoundError(f"Test input file not found: {input_csv}")
    
    # Run the conversion script
    cmd = [
        'python', str(script_path),
        str(input_csv),
        str(output_biom),
        '--type', 'content'
    ]
    
    print(f"Running command: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"Command failed with return code {result.returncode}")
        print(f"STDOUT: {result.stdout}")
        print(f"STDERR: {result.stderr}")
        return False
    
    # Verify both output files were created
    nutrients_biom = test_output_dir / 'test_food_content_nutrients.biom'
    compounds_biom = test_output_dir / 'test_food_content_compounds.biom'
    
    if not nutrients_biom.exists():
        print(f"Nutrients BIOM file was not created: {nutrients_biom}")
        return False
    
    if not compounds_biom.exists():
        print(f"Compounds BIOM file was not created: {compounds_biom}")
        return False
    
    # Load and validate the nutrients BIOM table
    try:
        nutrients_table = load_table(str(nutrients_biom))
        
        print(f"Nutrients BIOM table shape: {nutrients_table.shape}")
        print(f"Nutrients sample IDs: {list(nutrients_table.ids())}")
        print(f"Nutrients observation IDs: {list(nutrients_table.ids(axis='observation'))}")
        
        # Expected: 2 samples, 3 nutrient compounds (2, 3, 4)
        expected_samples = {'sample1', 'sample2'}
        expected_nutrients = {'2', '3', '4'}
        
        actual_samples = set(nutrients_table.ids())
        actual_nutrients = set(nutrients_table.ids(axis='observation'))
        
        if actual_samples != expected_samples:
            print(f"Nutrients sample ID mismatch. Expected: {expected_samples}, Got: {actual_samples}")
            return False
        
        if actual_nutrients != expected_nutrients:
            print(f"Nutrients observation ID mismatch. Expected: {expected_nutrients}, Got: {actual_nutrients}")
            return False
        
    except Exception as e:
        print(f"Error loading nutrients BIOM file: {e}")
        return False
    
    # Load and validate the compounds BIOM table
    try:
        compounds_table = load_table(str(compounds_biom))
        
        print(f"Compounds BIOM table shape: {compounds_table.shape}")
        print(f"Compounds sample IDs: {list(compounds_table.ids())}")
        print(f"Compounds observation IDs: {list(compounds_table.ids(axis='observation'))}")
        
        # Expected: 2 samples, 2 compounds (100, 101)
        expected_samples = {'sample1', 'sample2'}
        expected_compounds = {'100', '101'}
        
        actual_samples = set(compounds_table.ids())
        actual_compounds = set(compounds_table.ids(axis='observation'))
        
        if actual_samples != expected_samples:
            print(f"Compounds sample ID mismatch. Expected: {expected_samples}, Got: {actual_samples}")
            return False
        
        if actual_compounds != expected_compounds:
            print(f"Compounds observation ID mismatch. Expected: {expected_compounds}, Got: {actual_compounds}")
            return False
        
        # Check taxonomy metadata for compounds
        obs_metadata = compounds_table.metadata(axis='observation')
        if obs_metadata is None:
            print("Compounds observation metadata is missing")
            return False
        
        first_compound_metadata = obs_metadata[0]
        if 'taxonomy' not in first_compound_metadata:
            print("Taxonomy metadata is missing from compounds")
            return False
        
        print("✅ Food content conversion test passed")
        return True
        
    except Exception as e:
        print(f"Error loading compounds BIOM file: {e}")
        return False

def test_error_handling():
    """Test error handling for invalid inputs."""
    print("Testing error handling...")
    
    test_output_dir = get_test_output_dir()
    script_path = get_script_path()
    
    # Test with non-existent input file
    nonexistent_csv = test_output_dir / 'nonexistent.csv'
    output_biom = test_output_dir / 'error_test.biom'
    
    cmd = [
        'python', str(script_path),
        str(nonexistent_csv),
        str(output_biom),
        '--type', 'abundance'
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    # Should fail with non-zero return code
    if result.returncode == 0:
        print("Expected error for non-existent file, but command succeeded")
        return False
    
    print("✅ Error handling test passed")
    return True

def test_data_integrity():
    """Test that data values are preserved correctly in conversion."""
    print("Testing data integrity...")
    
    test_data_dir = get_test_data_dir()
    test_output_dir = get_test_output_dir()
    
    # Load original CSV data
    abundance_csv = pd.read_csv(test_data_dir / 'test_food_abundance.csv')
    abundance_biom = load_table(str(test_output_dir / 'test_food_abundance.biom'))
    
    # Check a specific data point
    # Find strawberry (food_id=83) in sample1
    strawberry_sample1 = abundance_csv[
        (abundance_csv['food_id'] == 83) & 
        (abundance_csv['sample_id'] == 'sample1')
    ]
    
    if len(strawberry_sample1) == 0:
        print("Could not find strawberry sample1 data in CSV")
        return False
    
    expected_abundance = strawberry_sample1['relative_abundance'].iloc[0]
    
    # Get the same value from BIOM table
    actual_abundance = abundance_biom.get_value_by_ids('83', 'sample1')
    
    # Allow for small floating point differences
    if abs(expected_abundance - actual_abundance) > 1e-10:
        print(f"Data integrity check failed. Expected: {expected_abundance}, Got: {actual_abundance}")
        return False
    
    print("✅ Data integrity test passed")
    return True

def test_edge_cases():
    """Test edge cases with scientific notation and data cleaning."""
    print("Testing edge cases...")
    
    test_data_dir = get_test_data_dir()
    test_output_dir = get_test_output_dir()
    script_path = get_script_path()
    
    # Test with edge case files if they exist
    edge_abundance_file = test_data_dir / 'test_food_abundance_edge_cases.csv'
    edge_content_file = test_data_dir / 'test_food_content_edge_cases.csv'
    
    if edge_abundance_file.exists():
        # Test food abundance edge cases
        output_biom = test_output_dir / 'test_edge_abundance.biom'
        cmd = [
            'python', str(script_path),
            str(edge_abundance_file),
            str(output_biom),
            '--type', 'abundance'
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Edge case abundance test failed: {result.stderr}")
            return False
        
        # Verify scientific notation handling
        biom_table = load_table(str(output_biom))
        obs_ids = set(biom_table.ids(axis='observation'))
        
        # Should convert 2e+05 to "200000"
        if '200000' not in obs_ids:
            print("Failed to handle scientific notation (2e+05)")
            return False
    
    if edge_content_file.exists():
        # Test food content edge cases
        output_biom = test_output_dir / 'test_edge_content.biom'
        cmd = [
            'python', str(script_path),
            str(edge_content_file),
            str(output_biom),
            '--type', 'content'
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Edge case content test failed: {result.stderr}")
            return False
        
        # Verify scientific notation in nutrients
        nutrients_biom = load_table(str(test_output_dir / 'test_edge_content_nutrients.biom'))
        nutrient_obs = set(nutrients_biom.ids(axis='observation'))
        
        # Should convert 3e+02 to "300"
        if '300' not in nutrient_obs:
            print("Failed to handle scientific notation in compound_id (3e+02)")
            return False
    
    print("✅ Edge cases test passed")
    return True

def main():
    """Run all MEDI CSV to BIOM integration tests."""
    print("Starting MEDI CSV to BIOM integration tests...")
    
    # Ensure output directory exists
    test_output_dir = get_test_output_dir()
    test_output_dir.mkdir(parents=True, exist_ok=True)
    
    # Run tests
    tests = [
        test_food_abundance_conversion,
        test_food_content_conversion,
        test_error_handling,
        test_data_integrity,
        test_edge_cases,
    ]
    
    passed = 0
    failed = 0
    
    for test in tests:
        try:
            if test():
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"❌ Test {test.__name__} raised exception: {e}")
            failed += 1
    
    print(f"\n{'='*60}")
    print(f"MEDI CSV to BIOM Integration Test Results:")
    print(f"✅ Passed: {passed}")
    print(f"❌ Failed: {failed}")
    print(f"{'='*60}")
    
    return failed == 0

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)