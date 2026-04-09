#!/usr/bin/env python3
"""
Convert MEDI CSV output files to BIOM format.
Supports both food_abundance.csv and food_content.csv formats.
"""

import argparse
import pandas as pd
import numpy as np
from biom import Table
from biom.util import biom_open
import sys
import os


def filter_duplicates(df):
    """Filter out duplicate rows based on columns [2:], keeping the most complete row."""
    if len(df) == 0:
        return df
    
    # Check if we have enough columns to group by
    if len(df.columns) <= 2:
        return df  # Can't filter duplicates without enough columns
    
    # Group by all columns except the first two (food_id, wikipedia_id)
    grouped = df.groupby(list(df.columns[2:]), dropna=False)
    
    filtered_rows = []
    for name, group in grouped:
        if len(group) > 1:
            # Multiple rows with same data in columns [2:]
            # Keep the row with the most non-null values in the first two columns
            best_idx = group[['food_id', 'wikipedia_id']].notna().sum(axis=1).idxmax()
            filtered_rows.append(group.loc[best_idx])
        else:
            # Single row, keep it
            filtered_rows.append(group.iloc[0])
    
    if len(filtered_rows) == 0:
        return df  # Return original if filtering failed
    
    # Create DataFrame from series list
    result_df = pd.DataFrame(filtered_rows)
    return result_df.reset_index(drop=True)


def filter_compound_duplicates(df):
    """Filter compound duplicates, preferentially keeping mg/100g units."""
    # Group by sample_id and compound_id
    grouped = df.groupby(['sample_id', 'compound_id'])
    
    filtered_rows = []
    for (sample_id, compound_id), group in grouped:
        if len(group) > 1:
            # Multiple rows for same compound in same sample
            # Prefer mg/100g unit if available
            mg_100g_rows = group[group['unit'] == 'mg/100g']
            if len(mg_100g_rows) > 0:
                filtered_rows.append(mg_100g_rows.iloc[0])
            else:
                # No mg/100g, just take the first one
                filtered_rows.append(group.iloc[0])
        else:
            # Single row, keep it
            filtered_rows.append(group.iloc[0])
    
    return pd.DataFrame(filtered_rows).reset_index(drop=True)


def create_food_abundance_biom(df):
    """Convert food_abundance.csv DataFrame to BIOM format."""
    # Filter duplicates first
    print(f"Original rows: {len(df)}")
    df = filter_duplicates(df)
    print(f"After duplicate filtering: {len(df)}")
    
    # Filter out rows with missing, NaN, or empty critical data
    # Remove rows where food_id or sample_id are NaN, empty string, or whitespace-only
    valid_mask = (
        df['food_id'].notna() & 
        df['sample_id'].notna() &
        (df['food_id'].astype(str).str.strip() != '') &
        (df['sample_id'].astype(str).str.strip() != '')
    )
    df = df[valid_mask]
    print(f"After cleaning invalid rows: {len(df)}")
    
    if len(df) == 0:
        raise ValueError("No valid food abundance data found after filtering")
    
    # Get unique sample and observation IDs
    sample_ids = sorted(df['sample_id'].unique())
    # Convert food_id to int, handling numpy strings, floats, and scientific notation
    food_ids = []
    for fid in df['food_id'].unique():
        if pd.isna(fid):
            continue
        try:
            # Convert to float first (handles scientific notation), then to int
            food_id_int = int(float(fid))
            food_ids.append(str(food_id_int))
        except (ValueError, TypeError):
            print(f"Warning: Could not convert food_id '{fid}' to integer, skipping")
            continue
    observation_ids = sorted(food_ids)
    
    # Create data matrix initialized with zeros
    data_matrix = np.zeros((len(observation_ids), len(sample_ids)))
    
    # Fill in the data matrix
    sample_id_to_idx = {sid: i for i, sid in enumerate(sample_ids)}
    obs_id_to_idx = {str(oid): i for i, oid in enumerate(observation_ids)}
    
    for _, row in df.iterrows():
        try:
            # Convert food_id consistently
            food_id_int = int(float(row['food_id']))
            food_id_str = str(food_id_int)
            obs_idx = obs_id_to_idx[food_id_str]
            sample_idx = sample_id_to_idx[row['sample_id']]
            data_matrix[obs_idx, sample_idx] = row['relative_abundance']
        except (ValueError, TypeError, KeyError) as e:
            print(f"Warning: Skipping row with invalid food_id '{row['food_id']}': {e}")
            continue
    
    # Create sample metadata (total_reads, total_raw_reads) as list
    sample_metadata = []
    for sample_id in sample_ids:
        sample_data = df[df['sample_id'] == sample_id].iloc[0]
        sample_metadata.append({
            'total_reads': int(sample_data['total_reads']),
            'total_raw_reads': int(sample_data['total_raw_reads'])
        })
    
    # Create observation metadata using direct taxonomy columns as list
    observation_metadata = []
    for obs_id_str in observation_ids:
        # Find matching food data by converting food_id to int consistently
        food_id = int(obs_id_str)
        matching_rows = df[df['food_id'].apply(lambda x: int(float(x)) if pd.notna(x) else None) == food_id]
        if len(matching_rows) == 0:
            print(f"Warning: No data found for food_id {food_id}")
            # Create default metadata
            observation_metadata.append({
                'taxonomy': ['', '', '', '', '', '', ''],
                'wikipedia_id': '',
                'food_group': '',
                'food_subgroup': '',
                'ncbi_taxonomy_id': ''
            })
            continue
        
        food_data = matching_rows.iloc[0]
        
        # Build taxonomy list from kingdom through species columns
        taxonomy_levels = ['kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species']
        taxonomy = []
        for level in taxonomy_levels:
            if level in food_data and pd.notna(food_data[level]) and str(food_data[level]).strip():
                taxonomy.append(str(food_data[level]).strip())
            else:
                taxonomy.append('')
        
        observation_metadata.append({
            'taxonomy': taxonomy,
            'wikipedia_id': str(food_data['wikipedia_id']) if pd.notna(food_data['wikipedia_id']) else '',
            'food_group': str(food_data['food_group']) if pd.notna(food_data['food_group']) else '',
            'food_subgroup': str(food_data['food_subgroup']) if pd.notna(food_data['food_subgroup']) else '',
            'ncbi_taxonomy_id': str(food_data['ncbi_taxonomy_id']) if pd.notna(food_data['ncbi_taxonomy_id']) else ''
        })
    
    # Create BIOM table
    biom_table = Table(
        data=data_matrix,
        observation_ids=observation_ids,
        sample_ids=sample_ids,
        observation_metadata=observation_metadata,
        sample_metadata=sample_metadata,
        table_id='MEDI Food Abundance',
        type='OTU table'
    )
    
    return biom_table


def create_nutrient_biom(df):
    """Convert nutrient rows from food_content.csv DataFrame to BIOM format."""
    # Filter to nutrient rows only
    nutrient_df = df[df['source_type'] == 'Nutrient'].copy()
    print(f"Processing {len(nutrient_df)} nutrient rows")
    
    # Filter out rows with missing, NaN, or empty critical data
    valid_mask = (
        nutrient_df['compound_id'].notna() & 
        nutrient_df['sample_id'].notna() &
        (nutrient_df['compound_id'].astype(str).str.strip() != '') &
        (nutrient_df['sample_id'].astype(str).str.strip() != '')
    )
    nutrient_df = nutrient_df[valid_mask]
    print(f"After cleaning invalid nutrient rows: {len(nutrient_df)}")
    
    if len(nutrient_df) == 0:
        raise ValueError("No valid nutrient data found after filtering")
    
    # Get unique sample and observation IDs
    sample_ids = sorted(nutrient_df['sample_id'].unique())
    # Convert compound_id to int, handling numpy strings, floats, and scientific notation
    compound_ids = []
    for cid in nutrient_df['compound_id'].unique():
        if pd.isna(cid):
            continue
        try:
            # Convert to float first (handles scientific notation), then to int
            compound_id_int = int(float(cid))
            compound_ids.append(str(compound_id_int))
        except (ValueError, TypeError):
            print(f"Warning: Could not convert compound_id '{cid}' to integer, skipping")
            continue
    observation_ids = sorted(compound_ids)
    
    # Create data matrix initialized with zeros
    data_matrix = np.zeros((len(observation_ids), len(sample_ids)))
    
    # Fill in the data matrix
    sample_id_to_idx = {sid: i for i, sid in enumerate(sample_ids)}
    obs_id_to_idx = {oid: i for i, oid in enumerate(observation_ids)}
    
    for _, row in nutrient_df.iterrows():
        try:
            # Convert compound_id consistently
            compound_id_int = int(float(row['compound_id']))
            compound_id_str = str(compound_id_int)
            obs_idx = obs_id_to_idx[compound_id_str]
            sample_idx = sample_id_to_idx[row['sample_id']]
            data_matrix[obs_idx, sample_idx] = row['abundance']
        except (ValueError, TypeError, KeyError) as e:
            print(f"Warning: Skipping nutrient row with invalid compound_id '{row['compound_id']}': {e}")
            continue
    
    # Create sample metadata (empty for food_content as no sample-specific metadata available)
    sample_metadata = [{} for _ in sample_ids]
    
    # Create observation metadata (nutrient-related metadata)
    observation_metadata = []
    for obs_id_str in observation_ids:
        # Find matching compound data by converting compound_id to int consistently
        compound_id = int(obs_id_str)
        matching_rows = nutrient_df[nutrient_df['compound_id'].apply(lambda x: int(float(x)) if pd.notna(x) else None) == compound_id]
        
        if len(matching_rows) > 0:
            compound_data = matching_rows.iloc[0]
            observation_metadata.append({
                'unit': str(compound_data['unit']) if pd.notna(compound_data['unit']) else '',
                'name': str(compound_data['name']) if pd.notna(compound_data['name']) else ''
            })
        else:
            # Default metadata if no match found
            observation_metadata.append({
                'unit': '',
                'name': f'Compound_{obs_id_str}'
            })
    
    # Create BIOM table
    biom_table = Table(
        data=data_matrix,
        observation_ids=observation_ids,
        sample_ids=sample_ids,
        observation_metadata=observation_metadata,
        sample_metadata=sample_metadata,
        table_id='MEDI Food Content - Nutrients',
        type='OTU table'
    )
    
    return biom_table


def create_compound_biom(df):
    """Convert compound rows from food_content.csv DataFrame to BIOM format."""
    # Filter to compound rows only
    compound_df = df[df['source_type'] == 'Compound'].copy()
    print(f"Processing {len(compound_df)} compound rows")
    
    # Handle empty compound data
    if len(compound_df) == 0:
        raise ValueError("No compound data found in input")
    
    # Filter compound duplicates (preferring mg/100g)
    compound_df = filter_compound_duplicates(compound_df)
    print(f"After compound duplicate filtering: {len(compound_df)}")
    
    # Filter out rows with missing, NaN, or empty critical data
    valid_mask = (
        compound_df['compound_id'].notna() & 
        compound_df['sample_id'].notna() &
        (compound_df['compound_id'].astype(str).str.strip() != '') &
        (compound_df['sample_id'].astype(str).str.strip() != '')
    )
    compound_df = compound_df[valid_mask]
    print(f"After cleaning invalid compound rows: {len(compound_df)}")
    
    if len(compound_df) == 0:
        raise ValueError("No valid compound data found after filtering")
    
    # Get unique sample and observation IDs
    sample_ids = sorted(compound_df['sample_id'].unique())
    # Convert compound_id to int, handling numpy strings, floats, and scientific notation
    compound_ids = []
    for cid in compound_df['compound_id'].unique():
        if pd.isna(cid):
            continue
        try:
            # Convert to float first (handles scientific notation), then to int
            compound_id_int = int(float(cid))
            compound_ids.append(str(compound_id_int))
        except (ValueError, TypeError):
            print(f"Warning: Could not convert compound_id '{cid}' to integer, skipping")
            continue
    observation_ids = sorted(compound_ids)
    
    # Create data matrix initialized with zeros
    data_matrix = np.zeros((len(observation_ids), len(sample_ids)))
    
    # Fill in the data matrix
    sample_id_to_idx = {sid: i for i, sid in enumerate(sample_ids)}
    obs_id_to_idx = {oid: i for i, oid in enumerate(observation_ids)}
    
    for _, row in compound_df.iterrows():
        try:
            # Convert compound_id consistently
            compound_id_int = int(float(row['compound_id']))
            compound_id_str = str(compound_id_int)
            obs_idx = obs_id_to_idx[compound_id_str]
            sample_idx = sample_id_to_idx[row['sample_id']]
            data_matrix[obs_idx, sample_idx] = row['abundance']
        except (ValueError, TypeError, KeyError) as e:
            print(f"Warning: Skipping compound row with invalid compound_id '{row['compound_id']}': {e}")
            continue
    
    # Create sample metadata (empty for food_content as no sample-specific metadata available)
    sample_metadata = [{} for _ in sample_ids]
    
    # Create observation metadata (compound-related metadata)
    observation_metadata = []
    for obs_id_str in observation_ids:
        # Find matching compound data by converting compound_id to int consistently
        compound_id = int(obs_id_str)
        matching_rows = compound_df[compound_df['compound_id'].apply(lambda x: int(float(x)) if pd.notna(x) else None) == compound_id]
        
        if len(matching_rows) > 0:
            compound_data = matching_rows.iloc[0]
            
            # Build taxonomy from kingdom, superclass, class, subclass, name
            taxonomy_levels = ['kingdom', 'superclass', 'class', 'subclass', 'name']
            taxonomy = []
            for level in taxonomy_levels:
                if level in compound_data and pd.notna(compound_data[level]) and str(compound_data[level]).strip():
                    taxonomy.append(str(compound_data[level]).strip())
                else:
                    taxonomy.append('')
            
            observation_metadata.append({
                'taxonomy': taxonomy,
                'unit': str(compound_data['unit']) if pd.notna(compound_data['unit']) else '',
                'name': str(compound_data['name']) if pd.notna(compound_data['name']) else '',
                'monomer_mass': str(compound_data['monomer_mass']) if pd.notna(compound_data['monomer_mass']) else '',
                'CAS': str(compound_data['CAS']) if pd.notna(compound_data['CAS']) else ''
            })
        else:
            # Default metadata if no match found
            observation_metadata.append({
                'taxonomy': ['', '', '', '', ''],
                'unit': '',
                'name': f'Compound_{obs_id_str}',
                'monomer_mass': '',
                'CAS': ''
            })
    
    # Create BIOM table
    biom_table = Table(
        data=data_matrix,
        observation_ids=observation_ids,
        sample_ids=sample_ids,
        observation_metadata=observation_metadata,
        sample_metadata=sample_metadata,
        table_id='MEDI Food Content - Compounds',
        type='OTU table'
    )
    
    return biom_table


def main():
    parser = argparse.ArgumentParser(description='Convert MEDI CSV files to BIOM format')
    parser.add_argument('input_csv', help='Input CSV file (food_abundance.csv or food_content.csv)')
    parser.add_argument('output_biom', help='Output BIOM file path (for food_content, will create _nutrients.biom and _compounds.biom)')
    parser.add_argument('--type', choices=['abundance', 'content'], required=True,
                       help='Type of CSV file: abundance for food_abundance.csv, content for food_content.csv')
    
    args = parser.parse_args()
    
    # Check if input file exists
    if not os.path.exists(args.input_csv):
        print(f"Error: Input file {args.input_csv} not found")
        sys.exit(1)
    
    try:
        # Read CSV file
        print(f"Reading CSV file: {args.input_csv}")
        df = pd.read_csv(args.input_csv)
        print(f"Loaded {len(df)} rows with columns: {list(df.columns)}")
        
        # Convert based on type
        if args.type == 'abundance':
            print("Converting food abundance data to BIOM format...")
            biom_table = create_food_abundance_biom(df)
            
            # Write BIOM file
            print(f"Writing BIOM file: {args.output_biom}")
            with biom_open(args.output_biom, 'w') as f:
                biom_table.to_hdf5(f, "Generated by MEDI CSV to BIOM converter")
            
            print(f"Successfully created BIOM file with {biom_table.shape[0]} observations and {biom_table.shape[1]} samples")
            
        elif args.type == 'content':
            print("Converting food content data to BIOM format...")
            
            # Create nutrient BIOM
            nutrient_biom = create_nutrient_biom(df)
            nutrient_output = args.output_biom.replace('.biom', '_nutrients.biom')
            print(f"Writing nutrient BIOM file: {nutrient_output}")
            with biom_open(nutrient_output, 'w') as f:
                nutrient_biom.to_hdf5(f, "Generated by MEDI CSV to BIOM converter - Nutrients")
            print(f"Successfully created nutrient BIOM file with {nutrient_biom.shape[0]} observations and {nutrient_biom.shape[1]} samples")
            
            # Create compound BIOM
            compound_biom = create_compound_biom(df)
            compound_output = args.output_biom.replace('.biom', '_compounds.biom')
            print(f"Writing compound BIOM file: {compound_output}")
            with biom_open(compound_output, 'w') as f:
                compound_biom.to_hdf5(f, "Generated by MEDI CSV to BIOM converter - Compounds")
            print(f"Successfully created compound BIOM file with {compound_biom.shape[0]} observations and {compound_biom.shape[1]} samples")
            
        else:
            print(f"Error: Unknown type {args.type}")
            sys.exit(1)
        
    except Exception as e:
        print(f"Error processing file: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()