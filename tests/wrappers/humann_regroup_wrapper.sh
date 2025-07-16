#!/bin/bash
# Docker wrapper script for humann_regroup_table
input_file="$1"
input_dir=$(dirname "$(readlink -f "$input_file")")
input_basename=$(basename "$input_file")

# Use the input directory as output directory
output_dir="$input_dir"

# Ensure we have absolute paths for Docker mounting
input_dir=$(realpath "$input_dir")
output_dir=$(realpath "$output_dir")

echo "HUMAnN regroup wrapper: input_file=$input_file, input_dir=$input_dir, output_dir=$output_dir"

# Mount the directory and run the command
docker run --rm \
    -v "$input_dir":/data \
    gutzcontainers.azurecr.io/humann:4.0.0a1-1 \
    humann_regroup_table -i "/data/$input_basename" -g uniref90_ko -o "/data/${input_basename%.*}_ko.biom"