#!/usr/bin/env python3
"""
Unit tests for medi_csv_to_biom.py internal functions.

Tests individual functions like filter_duplicates, create_food_abundance_biom, etc.
"""

import os
import sys
import unittest
import tempfile
import pandas as pd
import numpy as np
from pathlib import Path
from biom import Table

# Add the bin directory to the path so we can import the script
sys.path.insert(0, str(Path(__file__).parent.parent.parent / 'bin'))

# Import the functions from the medi_csv_to_biom script
from medi_csv_to_biom import (
    filter_duplicates,
    filter_compound_duplicates,
    create_food_abundance_biom,
    create_nutrient_biom,
    create_compound_biom
)

class TestMediCsvToBiom(unittest.TestCase):
    """Unit tests for MEDI CSV to BIOM conversion functions."""
    
    def setUp(self):
        """Set up test data."""
        # Create sample food abundance data
        self.food_abundance_data = pd.DataFrame({
            'food_id': [83, 83, 307, 334],
            'wikipedia_id': ['Strawberry', 'Strawberry', 'Blue mussel', 'Chicken'],
            'food_group': ['Fruits', 'Fruits', 'Aquatic foods', 'Animal foods'],
            'food_subgroup': ['Berries', 'Berries', 'Mollusks', 'Poultry'],
            'ncbi_taxonomy_id': [3747, 3747, 6550, 9031],
            'kingdom': ['', '', '', ''],
            'phylum': ['Streptophyta', 'Streptophyta', 'Mollusca', 'Chordata'],
            'class': ['Magnoliopsida', 'Magnoliopsida', 'Bivalvia', 'Aves'],
            'order': ['Rosales', 'Rosales', 'Mytilida', 'Galliformes'],
            'family': ['Rosaceae', 'Rosaceae', 'Mytilidae', 'Phasianidae'],
            'genus': ['Fragaria', 'Fragaria', 'Mytilus', 'Gallus'],
            'species': ['Fragaria x ananassa', 'Fragaria x ananassa', 'Mytilus edulis', 'Gallus gallus'],
            'sample_id': ['sample1', 'sample2', 'sample1', 'sample2'],
            'relative_abundance': [0.000015, 0.000950, 0.000025, 0.000070],
            'total_reads': [1500000, 1500000, 1500000, 1500000],
            'total_raw_reads': [750000, 750000, 750000, 750000]
        })
        
        # Create sample food content data with nutrients
        self.food_content_nutrients = pd.DataFrame({
            'sample_id': ['sample1', 'sample1', 'sample2', 'sample2'],
            'compound_id': [2, 3, 2, 3],
            'source_type': ['Nutrient', 'Nutrient', 'Nutrient', 'Nutrient'],
            'unit': ['mg/100g', 'mg/100g', 'mg/100g', 'mg/100g'],
            'abundance': [393.2, 24801.6, 445.8, 22500.4],
            'name': ['Proteins', 'Carbohydrate', 'Proteins', 'Carbohydrate']
        })
        
        # Create sample food content data with compounds
        self.food_content_compounds = pd.DataFrame({
            'sample_id': ['sample1', 'sample1', 'sample2', 'sample2'],
            'compound_id': [100, 101, 100, 101],
            'source_type': ['Compound', 'Compound', 'Compound', 'Compound'],
            'unit': ['mg/100g', 'mg/100g', 'mg/100g', 'ug/100g'],
            'abundance': [12.5, 8.9, 15.2, 8.9],
            'name': ['Test Compound', 'Another Compound', 'Test Compound', 'Another Compound'],
            'monomer_mass': [156.2, 284.5, 156.2, 284.5],
            'kingdom': ['Organic compounds', 'Organic compounds', 'Organic compounds', 'Organic compounds'],
            'superclass': ['Lipids and lipid-like molecules', 'Phenylpropanoids and polyketides', 'Lipids and lipid-like molecules', 'Phenylpropanoids and polyketides'],
            'class': ['Fatty acids', 'Flavonoids', 'Fatty acids', 'Flavonoids'],
            'subclass': ['Saturated fatty acids', 'Anthocyanins', 'Saturated fatty acids', 'Anthocyanins'],
            'CAS': ['123-45-6', '456-78-9', '123-45-6', '456-78-9']
        })
        
        # Create data with duplicates for testing filter functions
        self.duplicate_data = pd.DataFrame({
            'food_id': [83, 83, 307],
            'wikipedia_id': ['Strawberry', 'Strawberry_alt', ''],
            'sample_id': ['sample1', 'sample1', 'sample1'],
            'relative_abundance': [0.000015, 0.000015, 0.000025],
            'total_reads': [1500000, 1500000, 1500000],
            'total_raw_reads': [750000, 750000, 750000]
        })
        
        self.compound_duplicate_data = pd.DataFrame({
            'sample_id': ['sample1', 'sample1', 'sample2'],
            'compound_id': [100, 100, 101],
            'source_type': ['Compound', 'Compound', 'Compound'],
            'unit': ['mg/100g', 'g/100g', 'mg/100g'],
            'abundance': [12.5, 0.0125, 15.2],
            'name': ['Test Compound', 'Test Compound', 'Another Compound']
        })
    
    def test_filter_duplicates(self):
        """Test the filter_duplicates function."""
        filtered = filter_duplicates(self.duplicate_data)
        
        # Should keep 2 rows (one for each unique combination of columns [2:])
        self.assertEqual(len(filtered), 2)
        
        # Should prefer the row with more complete metadata (Strawberry over Strawberry_alt)
        strawberry_rows = filtered[filtered['food_id'] == 83]
        self.assertEqual(len(strawberry_rows), 1)
        self.assertEqual(strawberry_rows.iloc[0]['wikipedia_id'], 'Strawberry')
    
    def test_filter_compound_duplicates(self):
        """Test the filter_compound_duplicates function."""
        filtered = filter_compound_duplicates(self.compound_duplicate_data)
        
        # Should keep 2 rows (one per sample-compound combination)
        self.assertEqual(len(filtered), 2)
        
        # Should prefer mg/100g unit over g/100g
        compound_100_sample1 = filtered[
            (filtered['compound_id'] == 100) & 
            (filtered['sample_id'] == 'sample1')
        ]
        self.assertEqual(len(compound_100_sample1), 1)
        self.assertEqual(compound_100_sample1.iloc[0]['unit'], 'mg/100g')
        self.assertEqual(compound_100_sample1.iloc[0]['abundance'], 12.5)
    
    def test_create_food_abundance_biom(self):
        """Test the create_food_abundance_biom function."""
        biom_table = create_food_abundance_biom(self.food_abundance_data)
        
        # Check basic structure
        self.assertIsInstance(biom_table, Table)
        self.assertEqual(biom_table.shape, (3, 2))  # 3 foods, 2 samples
        
        # Check sample IDs
        sample_ids = set(biom_table.ids())
        expected_samples = {'sample1', 'sample2'}
        self.assertEqual(sample_ids, expected_samples)
        
        # Check observation IDs (food IDs as strings)
        obs_ids = set(biom_table.ids(axis='observation'))
        expected_obs = {'83', '307', '334'}
        self.assertEqual(obs_ids, expected_obs)
        
        # Check specific data value
        strawberry_sample2_value = biom_table.get_value_by_ids('83', 'sample2')
        self.assertAlmostEqual(strawberry_sample2_value, 0.000950, places=6)
        
        # Check metadata exists
        sample_metadata = biom_table.metadata(axis='sample')
        obs_metadata = biom_table.metadata(axis='observation')
        
        self.assertIsNotNone(sample_metadata)
        self.assertIsNotNone(obs_metadata)
        
        # Check sample metadata contains expected fields
        sample1_metadata = dict(zip(biom_table.ids(), sample_metadata))[('sample1')]
        self.assertIn('total_reads', sample1_metadata)
        self.assertIn('total_raw_reads', sample1_metadata)
        self.assertEqual(sample1_metadata['total_reads'], 1500000)
        
        # Check observation metadata contains taxonomy
        obs83_metadata = dict(zip(biom_table.ids(axis='observation'), obs_metadata))['83']
        self.assertIn('taxonomy', obs83_metadata)
        self.assertIn('food_group', obs83_metadata)
        self.assertEqual(obs83_metadata['food_group'], 'Fruits')
        
        # Check taxonomy structure
        taxonomy = obs83_metadata['taxonomy']
        self.assertEqual(len(taxonomy), 7)  # kingdom through species
        self.assertEqual(taxonomy[1], 'Streptophyta')  # phylum
        self.assertEqual(taxonomy[6], 'Fragaria x ananassa')  # species
    
    def test_create_nutrient_biom(self):
        """Test the create_nutrient_biom function."""
        # Create combined data with nutrients
        combined_data = self.food_content_nutrients.copy()
        
        biom_table = create_nutrient_biom(combined_data)
        
        # Check basic structure
        self.assertIsInstance(biom_table, Table)
        self.assertEqual(biom_table.shape, (2, 2))  # 2 nutrients, 2 samples
        
        # Check sample IDs
        sample_ids = set(biom_table.ids())
        expected_samples = {'sample1', 'sample2'}
        self.assertEqual(sample_ids, expected_samples)
        
        # Check observation IDs (compound IDs as strings)
        obs_ids = set(biom_table.ids(axis='observation'))
        expected_obs = {'2', '3'}
        self.assertEqual(obs_ids, expected_obs)
        
        # Check specific data value
        protein_sample1_value = biom_table.get_value_by_ids('2', 'sample1')
        self.assertAlmostEqual(protein_sample1_value, 393.2, places=1)
        
        # Check metadata
        obs_metadata = biom_table.metadata(axis='observation')
        self.assertIsNotNone(obs_metadata)
        
        # Check observation metadata contains expected fields
        obs2_metadata = dict(zip(biom_table.ids(axis='observation'), obs_metadata))['2']
        self.assertIn('unit', obs2_metadata)
        self.assertIn('name', obs2_metadata)
        self.assertEqual(obs2_metadata['unit'], 'mg/100g')
        self.assertEqual(obs2_metadata['name'], 'Proteins')
    
    def test_create_compound_biom(self):
        """Test the create_compound_biom function."""
        biom_table = create_compound_biom(self.food_content_compounds)
        
        # Check basic structure
        self.assertIsInstance(biom_table, Table)
        self.assertEqual(biom_table.shape, (2, 2))  # 2 compounds, 2 samples
        
        # Check sample IDs
        sample_ids = set(biom_table.ids())
        expected_samples = {'sample1', 'sample2'}
        self.assertEqual(sample_ids, expected_samples)
        
        # Check observation IDs (compound IDs as strings)
        obs_ids = set(biom_table.ids(axis='observation'))
        expected_obs = {'100', '101'}
        self.assertEqual(obs_ids, expected_obs)
        
        # Check specific data value
        compound_100_sample1_value = biom_table.get_value_by_ids('100', 'sample1')
        self.assertAlmostEqual(compound_100_sample1_value, 12.5, places=1)
        
        # Check metadata
        obs_metadata = biom_table.metadata(axis='observation')
        self.assertIsNotNone(obs_metadata)
        
        # Check observation metadata contains expected fields
        obs100_metadata = dict(zip(biom_table.ids(axis='observation'), obs_metadata))['100']
        self.assertIn('taxonomy', obs100_metadata)
        self.assertIn('unit', obs100_metadata)
        self.assertIn('name', obs100_metadata)
        self.assertIn('monomer_mass', obs100_metadata)
        self.assertIn('CAS', obs100_metadata)
        
        # Check taxonomy structure
        taxonomy = obs100_metadata['taxonomy']
        self.assertEqual(len(taxonomy), 5)  # kingdom through name
        self.assertEqual(taxonomy[0], 'Organic compounds')  # kingdom
        self.assertEqual(taxonomy[4], 'Test Compound')  # name
        
        self.assertEqual(obs100_metadata['unit'], 'mg/100g')
        self.assertEqual(obs100_metadata['CAS'], '123-45-6')
    
    def test_empty_data_handling(self):
        """Test handling of empty dataframes."""
        empty_df = pd.DataFrame()
        
        # Should handle empty dataframes gracefully
        with self.assertRaises((ValueError, IndexError, KeyError)):
            create_food_abundance_biom(empty_df)
    
    def test_missing_columns_handling(self):
        """Test handling of missing required columns."""
        incomplete_df = pd.DataFrame({
            'food_id': [83],
            'sample_id': ['sample1']
            # Missing required columns
        })
        
        # Should raise an error for missing columns
        with self.assertRaises(KeyError):
            create_food_abundance_biom(incomplete_df)
    
    def test_data_types_preservation(self):
        """Test that data types are preserved correctly."""
        biom_table = create_food_abundance_biom(self.food_abundance_data)
        
        # Check that abundance values are numeric
        data_matrix = biom_table.matrix_data.toarray()
        self.assertTrue(np.issubdtype(data_matrix.dtype, np.number))
        
        # Check that all values are non-negative
        self.assertTrue(np.all(data_matrix >= 0))
    
    def test_scientific_notation_food_ids(self):
        """Test handling of scientific notation in food_id."""
        # Create test data with scientific notation
        sci_data = pd.DataFrame({
            'food_id': [np.str_('83.0'), '2e+05', 307.0],
            'wikipedia_id': ['Strawberry', 'Big Food', 'Blue mussel'],
            'food_group': ['Fruits', 'Processed', 'Aquatic foods'],
            'food_subgroup': ['Berries', 'Industrial', 'Mollusks'],
            'ncbi_taxonomy_id': [3747, 12345, 6550],
            'kingdom': ['', '', ''],
            'phylum': ['Streptophyta', 'Bacteria', 'Mollusca'],
            'class': ['Magnoliopsida', 'Proteobacteria', 'Bivalvia'],
            'order': ['Rosales', 'Enterobacterales', 'Mytilida'],
            'family': ['Rosaceae', 'Enterobacteriaceae', 'Mytilidae'],
            'genus': ['Fragaria', 'Escherichia', 'Mytilus'],
            'species': ['Fragaria x ananassa', 'Escherichia coli', 'Mytilus edulis'],
            'sample_id': ['sample1', 'sample1', 'sample2'],
            'relative_abundance': [0.000015, 0.000100, 0.000025],
            'total_reads': [1500000, 1500000, 1500000],
            'total_raw_reads': [750000, 750000, 750000]
        })
        
        biom_table = create_food_abundance_biom(sci_data)
        
        # Should convert 2e+05 to "200000"
        obs_ids = set(biom_table.ids(axis='observation'))
        self.assertIn('200000', obs_ids)
        
        # Should convert 83.0 to "83"
        self.assertIn('83', obs_ids)
        
        # Should convert 307.0 to "307"  
        self.assertIn('307', obs_ids)
        
        self.assertEqual(len(obs_ids), 3)
    
    def test_scientific_notation_compound_ids(self):
        """Test handling of scientific notation in compound_id."""
        # Create test data with scientific notation in compound_id
        sci_compound_data = pd.DataFrame({
            'sample_id': ['sample1', 'sample1'],
            'compound_id': [np.str_('2.0'), '3e+02'],
            'source_type': ['Nutrient', 'Nutrient'],
            'unit': ['mg/100g', 'mg/100g'],
            'abundance': [393.2, 24801.6],
            'name': ['Proteins', 'Carbohydrate']
        })
        
        nutrient_biom = create_nutrient_biom(sci_compound_data)
        obs_ids = set(nutrient_biom.ids(axis='observation'))
        
        # Should convert 3e+02 to "300"
        self.assertIn('300', obs_ids)
        
        # Should convert 2.0 to "2"
        self.assertIn('2', obs_ids)
        
        self.assertEqual(len(obs_ids), 2)
    
    def test_data_cleaning_invalid_rows(self):
        """Test that invalid rows with NaN/empty data are properly filtered."""
        # Create data with invalid rows
        dirty_data = pd.DataFrame({
            'food_id': [83, np.nan, '', 307, '  '],  # Mix of valid, NaN, empty, and whitespace
            'wikipedia_id': ['Strawberry', '', '', 'Blue mussel', ''],
            'food_group': ['Fruits', '', '', 'Aquatic foods', ''],
            'food_subgroup': ['Berries', '', '', 'Mollusks', ''],
            'ncbi_taxonomy_id': [3747, np.nan, np.nan, 6550, np.nan],
            'kingdom': ['', '', '', '', ''],
            'phylum': ['Streptophyta', '', '', 'Mollusca', ''],
            'class': ['Magnoliopsida', '', '', 'Bivalvia', ''],
            'order': ['Rosales', '', '', 'Mytilida', ''],
            'family': ['Rosaceae', '', '', 'Mytilidae', ''],
            'genus': ['Fragaria', '', '', 'Mytilus', ''],
            'species': ['Fragaria x ananassa', '', '', 'Mytilus edulis', ''],
            'sample_id': ['sample1', 'sample1', np.nan, 'sample2', ''],  # Mix of valid, NaN, empty
            'relative_abundance': [0.000015, 0.0, 0.0, 0.000025, 0.0],
            'total_reads': [1500000, 1500000, 1500000, 1500000, 1500000],
            'total_raw_reads': [750000, 750000, 750000, 750000, 750000]
        })
        
        biom_table = create_food_abundance_biom(dirty_data)
        
        # Should only keep rows with valid food_id and sample_id
        obs_ids = set(biom_table.ids(axis='observation'))
        sample_ids = set(biom_table.ids())
        
        # Should have only 2 valid foods (83, 307)
        self.assertEqual(len(obs_ids), 2)
        self.assertEqual(obs_ids, {'83', '307'})
        
        # Should have only 2 valid samples
        self.assertEqual(len(sample_ids), 2)
        self.assertEqual(sample_ids, {'sample1', 'sample2'})
    
    def test_numpy_string_handling(self):
        """Test handling of numpy string types."""
        # Create data with explicit numpy strings
        numpy_data = pd.DataFrame({
            'food_id': [np.str_('123.0'), np.str_('456.0')],
            'wikipedia_id': ['Food1', 'Food2'],
            'food_group': ['Group1', 'Group2'],
            'food_subgroup': ['Sub1', 'Sub2'],
            'ncbi_taxonomy_id': [111, 222],
            'kingdom': ['', ''],
            'phylum': ['P1', 'P2'],
            'class': ['C1', 'C2'],
            'order': ['O1', 'O2'],
            'family': ['F1', 'F2'],
            'genus': ['G1', 'G2'],
            'species': ['S1', 'S2'],
            'sample_id': ['sample1', 'sample1'],
            'relative_abundance': [0.1, 0.2],
            'total_reads': [1000, 1000],
            'total_raw_reads': [500, 500]
        })
        
        biom_table = create_food_abundance_biom(numpy_data)
        
        # Should convert numpy strings properly
        obs_ids = set(biom_table.ids(axis='observation'))
        expected_obs = {'123', '456'}
        self.assertEqual(obs_ids, expected_obs)
    
    def test_empty_data_error_handling(self):
        """Test that functions properly error when no valid data remains."""
        # Create DataFrame with all invalid data
        empty_data = pd.DataFrame({
            'food_id': [np.nan, '', np.nan],
            'wikipedia_id': ['', '', ''],
            'food_group': ['', '', ''],
            'food_subgroup': ['', '', ''],
            'ncbi_taxonomy_id': [np.nan, np.nan, np.nan],
            'kingdom': ['', '', ''],
            'phylum': ['', '', ''],
            'class': ['', '', ''],
            'order': ['', '', ''],
            'family': ['', '', ''],
            'genus': ['', '', ''],
            'species': ['', '', ''],
            'sample_id': ['sample1', '', np.nan],
            'relative_abundance': [0.0, 0.0, 0.0],
            'total_reads': [1000, 1000, 1000],
            'total_raw_reads': [500, 500, 500]
        })
        
        # Should raise ValueError when no valid data
        with self.assertRaises(ValueError) as context:
            create_food_abundance_biom(empty_data)
        
        self.assertIn("No valid food abundance data found", str(context.exception))
    
    def test_compound_data_cleaning(self):
        """Test data cleaning for compound data with edge cases."""
        # Create compound data with invalid rows
        dirty_compound_data = pd.DataFrame({
            'sample_id': ['sample1', '', 'sample2', np.nan],
            'compound_id': [100.0, 101.0, np.nan, '1.0e2'],
            'source_type': ['Compound', 'Compound', 'Compound', 'Compound'],
            'unit': ['mg/100g', 'mg/100g', 'mg/100g', 'mg/100g'],
            'abundance': [12.5, 15.2, 8.9, 20.0],
            'name': ['Compound1', 'Compound2', 'Compound3', 'Compound4'],
            'kingdom': ['Organic compounds', 'Organic compounds', 'Organic compounds', 'Organic compounds'],
            'superclass': ['Lipids', 'Lipids', 'Lipids', 'Lipids'],
            'class': ['Fatty acids', 'Fatty acids', 'Fatty acids', 'Fatty acids'],
            'subclass': ['Saturated', 'Saturated', 'Saturated', 'Saturated'],
            'monomer_mass': [156.2, 284.5, 300.1, 400.0],
            'CAS': ['123-45-6', '456-78-9', '789-01-2', '345-67-8']
        })
        
        compound_biom = create_compound_biom(dirty_compound_data)
        
        # Should only keep rows with valid sample_id and compound_id
        sample_ids = set(compound_biom.ids())
        obs_ids = set(compound_biom.ids(axis='observation'))
        
        # Should have only 1 valid sample (sample1) and 1 valid compound (100)
        self.assertEqual(sample_ids, {'sample1'})
        self.assertEqual(obs_ids, {'100'})


def main():
    """Run the unit tests."""
    unittest.main(verbosity=2)


if __name__ == "__main__":
    main()