#!/usr/bin/env python3

import sys
import subprocess
import numpy as np
from tempfile import TemporaryDirectory
from os.path import join
from biom import Table, load_table
from biom.util import biom_open
from scipy.cluster.hierarchy import linkage, leaves_list, dendrogram

def execute_humann_regroup_table(gf_biom, group, output_file):
    """
    Written by chatGPT, thanks
    """
    # Construct the output file name
    # Construct the command as a list of arguments
    command = [
        "humann_regroup_table",
        "-i", gf_biom,
        "-g", group,
        "-o", output_file
    ]
    
    # Execute the command
    result = subprocess.run(command, 
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, 
                            universal_newlines=True)
    
    # Check if the command was successful
    if result.returncode == 0:
        print("Command executed successfully.")
        print(result.stdout)
    else:
        print("Command failed.")
        print(result.stderr)
    
    return result.returncode, result.stdout, result.stderr


def split_biom(original, max_samples=100):
    samples = original.ids(axis='sample')
    ordered_samples = samples[cluster_and_order_columns_by_similarity_sparse(original.matrix_data)]

    f = lambda id_, _: int(np.floor(list(ordered_samples).index(id_) / max_samples))

    splits = original.partition(f)

    return(splits)


def join_biom_files(input_files):

    split_bioms = []

    for x in input_files:
        split_bioms.append(load_table(x))

    base = split_bioms.pop(0)

    joined_biom = base.concat(split_bioms)

    return(joined_biom)


def cluster_and_order_columns_by_similarity_sparse(sparse_matrix):
    # Convert the sparse matrix to a binary matrix (presence/absence)
    binary_matrix = sparse_matrix.copy()
    binary_matrix.data = np.ones_like(binary_matrix.data)
    
    # Transpose the binary matrix to cluster columns
    binary_matrix_T = binary_matrix.transpose()
    
    # Convert the transposed binary matrix to a dense matrix for clustering
    binary_matrix_T_dense = binary_matrix_T.toarray()
    
    # Perform hierarchical/agglomerative clustering
    Z = linkage(binary_matrix_T_dense, method='ward')
    
    # Get the ordered list of columns
    ordered_columns = leaves_list(Z)
    
    return(ordered_columns)


def parition_table(biom_fp, max_s, outdir='./'):
    print('Loading input file')
    biom_orig = load_table(biom_fp)
    print('Original: {0} samples x {1} observations'.format(biom_orig.shape[1],biom_orig.shape[0]))

    print('Partitioning input file')
    biom_splits = split_biom(biom_orig, max_s)

    split_fps = []

    i = 0
    for b, t in biom_splits:
        i = i + 1
        temp_name = join(outdir, 'split_%s.biom' % i)
        print('Saving split %s' % i)

        t.remove_empty(axis='observation', inplace=True)
        print('Split: {0} samples x {1} observations'.format(t.shape[1],t.shape[0]))
       
        with biom_open(temp_name, 'w') as f:
            t.to_hdf5(f, 'split %s' % i)
        split_fps.append(temp_name)

    return(split_fps)


def main():
    args = sys.argv

    biom_fp = args[1]
    group = args[2]
    output_fp = args[3]
    if len(args) == 5:
        max_s = int(args[4])
    elif len(args) == 4:
        max_s = 100
    else:
        raise ValueError('Must have three or four arguments')


    

    with TemporaryDirectory(dir='') as td:
        split_fps = parition_table(biom_fp, max_s, outdir=td)

        regrouped_fps = []
        i = 0
        for temp_name in split_fps:
            i = i + 1
            print(temp_name)

            proc_name = '_regrouped.'.join(temp_name.split('.'))
            print(proc_name)
            regrouped_fps.append(proc_name)
            print('Regrouping split %s' % i)
            execute_humann_regroup_table(temp_name,
                                         group,
                                         proc_name)

        print('Joining split processed tables')
        joined = join_biom_files(regrouped_fps)

    print('Saving joined table')
    with biom_open(output_fp, 'w') as f:
        joined.to_hdf5(f, 'Regrouped HUMAnN table') 



if __name__ == "__main__":
    main()