#!/usr/bin/env python3

import sys
import subprocess
import numpy as np
import argparse
import os
import glob
import re
import shlex
from tempfile import TemporaryDirectory
from os.path import join, basename, dirname, exists
from biom import Table, load_table
from biom.util import biom_open
from scipy.cluster.hierarchy import linkage, leaves_list, dendrogram


def execute_command(input_file, command_string, output_location='.'):
    """
    Execute a command with the input file and provided arguments.
    
    Args:
        input_file: Path to input file
        command_string: Command string where {input} will be replaced with input_file
        output_location: Directory where output files will be created
    
    Returns:
        Return code and list of all files in output location after command execution
    """
    # Get the absolute path of the input file
    input_file_abs = os.path.abspath(input_file)
    
    # Replace {input} placeholder with actual input file
    command_with_input = command_string.replace('{input}', input_file_abs)
    
    # Parse the command string into arguments
    cmd = shlex.split(command_with_input)
    
    print(f"Executing: {' '.join(cmd)}")
    
    # Get files before command execution
    files_before = set()
    if exists(output_location):
        files_before = set(os.listdir(output_location))
    
    result = subprocess.run(cmd, 
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, 
                            universal_newlines=True)
    
    if result.returncode != 0:
        print(f"Command failed with return code {result.returncode}")
        print(f"STDERR: {result.stderr}")
        print(f"STDOUT: {result.stdout}")
        return result.returncode, []
    
    # Get files after command execution
    files_after = set()
    if exists(output_location):
        files_after = set(os.listdir(output_location))
    
    # Find new files created by the command
    new_files = files_after - files_before
    new_file_paths = [join(output_location, f) for f in new_files]
    
    return result.returncode, new_file_paths


def match_output_files(file_paths, regex_patterns):
    """
    Match output files against regex patterns and group them.
    
    Args:
        file_paths: List of file paths to match
        regex_patterns: List of regex patterns to match against filenames
    
    Returns:
        Dictionary mapping pattern index to list of matching files
    """
    grouped_files = {}
    
    for i, pattern in enumerate(regex_patterns):
        compiled_pattern = re.compile(pattern)
        matching_files = []
        
        for file_path in file_paths:
            filename = basename(file_path)
            if compiled_pattern.search(filename):
                matching_files.append(file_path)
        
        if matching_files:
            grouped_files[i] = matching_files
            print(f"Pattern {i} ('{pattern}') matched {len(matching_files)} files: {[basename(f) for f in matching_files]}")
    
    return grouped_files


def split_biom(original, max_samples=100):
    """Split biom table into smaller chunks based on sample clustering."""
    samples = original.ids(axis='sample')
    ordered_samples = samples[cluster_and_order_columns_by_similarity_sparse(original.matrix_data)]

    f = lambda id_, _: int(np.floor(list(ordered_samples).index(id_) / max_samples))

    splits = original.partition(f)

    return splits


def join_biom_files(input_files):
    """Join multiple biom files into a single table."""
    split_bioms = []

    for x in input_files:
        if exists(x):
            try:
                split_bioms.append(load_table(x))
            except Exception as e:
                print(f"Warning: Could not load {x}: {e}")
                continue

    if not split_bioms:
        return None

    base = split_bioms.pop(0)
    joined_biom = base.concat(split_bioms)

    return joined_biom


def cluster_and_order_columns_by_similarity_sparse(sparse_matrix):
    """Cluster samples based on similarity for optimal splitting."""
    n_samples = sparse_matrix.shape[1]
    
    # Handle edge cases
    if n_samples <= 1:
        return np.arange(n_samples)
    
    # Convert the sparse matrix to a binary matrix (presence/absence)
    binary_matrix = sparse_matrix.copy()
    binary_matrix.data = np.ones_like(binary_matrix.data)
    
    # Transpose the binary matrix to cluster columns
    binary_matrix_T = binary_matrix.transpose()
    
    # Convert the transposed binary matrix to a dense matrix for clustering
    binary_matrix_T_dense = binary_matrix_T.toarray()
    
    # Handle case where all samples are identical
    if np.all(binary_matrix_T_dense == binary_matrix_T_dense[0]):
        return np.arange(n_samples)
    
    try:
        # Perform hierarchical/agglomerative clustering
        Z = linkage(binary_matrix_T_dense, method='ward')
        
        # Get the ordered list of columns
        ordered_columns = leaves_list(Z)
        
        return ordered_columns
    except Exception:
        # If clustering fails, return natural order
        return np.arange(n_samples)


def partition_table(biom_fp, max_s, outdir='./'):
    """Partition biom table into smaller chunks."""
    print('Loading input file')
    biom_orig = load_table(biom_fp)
    print('Original: {0} samples x {1} observations'.format(biom_orig.shape[1], biom_orig.shape[0]))

    print('Partitioning input file')
    biom_splits = split_biom(biom_orig, max_s)

    split_fps = []

    i = 0
    for b, t in biom_splits:
        i = i + 1
        temp_name = join(outdir, 'split_%s.biom' % i)
        print('Saving split %s' % i)

        t.remove_empty(axis='observation', inplace=True)
        print('Split: {0} samples x {1} observations'.format(t.shape[1], t.shape[0]))
       
        with biom_open(temp_name, 'w') as f:
            t.to_hdf5(f, 'split %s' % i)
        split_fps.append(temp_name)

    return split_fps


def main():
    parser = argparse.ArgumentParser(description='Process biom files with clustering to avoid memory issues')
    parser.add_argument('input_biom', help='Input biom file')
    parser.add_argument('command', help='Command to execute on each split as a single string (use {input} as placeholder for input file)')
    parser.add_argument('--max-samples', type=int, default=100, help='Maximum samples per split (default: 100)')
    parser.add_argument('--final-output-dir', default='.', help='Directory for final joined output files (default: current directory)')
    parser.add_argument('--command-output-location', default='.', help='Directory where command creates output files (default: current directory)')
    parser.add_argument('--output-regex-patterns', nargs='+', required=True, help='Regex patterns to match and group output files (e.g., ".*_stratified\\.biom$" ".*_unstratified\\.biom$")')
    parser.add_argument('--output-group-names', nargs='+', help='Names for output groups (must match number of regex patterns)')
    parser.add_argument('--output-prefix', help='Prefix for final output files (default: input filename without extension)')
    parser.add_argument('--no-join', action='store_true', help='Do not join results, just process splits and copy outputs')
    
    args = parser.parse_args()

    biom_fp = args.input_biom
    command_string = args.command
    max_samples = args.max_samples
    final_output_dir = args.final_output_dir
    command_output_location = args.command_output_location
    regex_patterns = args.output_regex_patterns
    group_names = args.output_group_names
    output_prefix = args.output_prefix or basename(biom_fp).replace('.biom', '')
    
    # Validate group names
    if group_names and len(group_names) != len(regex_patterns):
        print(f"Error: Number of group names ({len(group_names)}) must match number of regex patterns ({len(regex_patterns)})")
        sys.exit(1)
    
    # Use default group names if not provided
    if not group_names:
        group_names = [f"group_{i}" for i in range(len(regex_patterns))]
    
    # Create output directory if it doesn't exist
    os.makedirs(final_output_dir, exist_ok=True)

    with TemporaryDirectory(dir='') as td:
        # Split the input biom file
        split_fps = partition_table(biom_fp, max_samples, outdir=td)

        # Process each split
        all_grouped_files = {i: [] for i in range(len(regex_patterns))}
        
        for i, temp_name in enumerate(split_fps, 1):
            print(f'Processing split {i}: {temp_name}')
            
            # Change to temp directory for processing
            original_cwd = os.getcwd()
            os.chdir(td)
            
            try:
                # Set up command output location relative to temp directory
                cmd_output_loc = command_output_location if command_output_location != '.' else td
                if not os.path.isabs(cmd_output_loc):
                    cmd_output_loc = join(td, cmd_output_loc)
                
                os.makedirs(cmd_output_loc, exist_ok=True)
                
                # Execute command and get output files
                return_code, output_files = execute_command(basename(temp_name), command_string, cmd_output_loc)
                
                if return_code != 0:
                    print(f"Warning: Command failed for split {i}")
                    continue
                
                # Match output files against regex patterns
                grouped_files = match_output_files(output_files, regex_patterns)
                
                # Add to overall collection
                for group_idx, files in grouped_files.items():
                    all_grouped_files[group_idx].extend(files)
                        
            finally:
                os.chdir(original_cwd)

        if args.no_join:
            # Just copy files to output directory without joining
            for group_idx, files in all_grouped_files.items():
                group_name = group_names[group_idx]
                for file in files:
                    src = file if os.path.isabs(file) else join(td, file)
                    dst_name = f"{output_prefix}_{group_name}_{basename(file)}"
                    dst = join(final_output_dir, dst_name)
                    if exists(src):
                        subprocess.run(['cp', src, dst])
                        print(f"Copied {src} to {dst}")
        else:
            # Join results for each group
            for group_idx, files in all_grouped_files.items():
                group_name = group_names[group_idx]
                
                if not files:
                    print(f"No files found for group {group_idx} ({group_name})")
                    continue
                
                print(f'Joining {len(files)} files for group: {group_name}')
                
                # Convert to absolute paths if needed
                abs_files = []
                for f in files:
                    if os.path.isabs(f):
                        abs_files.append(f)
                    else:
                        abs_files.append(join(td, f))
                
                # Join biom files
                joined = join_biom_files(abs_files)
                
                if joined is not None:
                    # Determine output filename
                    output_fp = join(final_output_dir, f'{output_prefix}_{group_name}.biom')
                    
                    print(f'Saving joined table: {output_fp}')
                    with biom_open(output_fp, 'w') as f:
                        joined.to_hdf5(f, f'Processed {group_name} table')
                else:
                    print(f'No valid biom files found for group: {group_name}')


if __name__ == "__main__":
    main()