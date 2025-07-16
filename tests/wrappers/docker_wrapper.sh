#!/bin/bash
# Docker wrapper script for HUMAnN commands
input_file="$1"
input_dir=$(dirname "$(readlink -f "$input_file")")
input_basename=$(basename "$input_file")

# Use the input directory as output directory (working directory for safe_cluster_process.py)
output_dir="$input_dir"

# Ensure we have absolute paths for Docker mounting
input_dir=$(realpath "$input_dir")
output_dir=$(realpath "$output_dir")

echo "Docker wrapper: input_file=$input_file, input_dir=$input_dir, output_dir=$output_dir"

# Mount the directory and run the command
docker run --rm \
    -v "$input_dir":/data \
    gutzcontainers.azurecr.io/humann:4.0.0a1-1 \
    humann_split_stratified_table -i "/data/$input_basename" -o "/data"
