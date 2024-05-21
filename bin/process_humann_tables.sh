#!/usr/bin/env bash

# <!-- argument code written with ChatGPT4o
# Function to display help message
show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo "Regroup and split HUMAnN genefamily table data, producing biom-format outputs."
    echo
    echo "Options:"
    echo "  -i, --input       TABLE_PATH   Path to the input table file."
    echo "  -o, --output-dir  OUTPUT_DIR   Directory to save the output file."
    echo "  -n, --name        OUTPUT_NAME  Name of the output file."
    echo "  -h, --help                     Display this help message."
}

# Check if no arguments were provided
if [ "$#" -eq 0 ]; then
    show_help
    exit 1
fi

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -i|--input)
            TABLE_PATH="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -n|--name)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check for required arguments
if [ -z "$TABLE_PATH" ] || [ -z "$OUTPUT_DIR" ] || [ -z "$OUTPUT_NAME" ]; then
    echo "Error: Missing required arguments."
    show_help
    exit 1
fi

# Example processing command (replace with actual processing logic)
echo "Processing table data..."
echo "Input Table Path: $TABLE_PATH"
echo "Output Directory: $OUTPUT_DIR"
echo "Output Name: $OUTPUT_NAME"

# !-->

BIOM_PATH=${OUTPUT_DIR}/${OUTPUT_NAME}_genefamilies.biom

# convert to biom

biom convert \
    --input-fp $TABLE_PATH \
    --output-fp $BIOM_PATH \
    --table-type 'Function table' \
    --to-hdf5

GROUPS=('uniref90_ko' 'uniref90_rxn' 'uniref90_pfam')
 
for GROUP in "${GROUPS[@]}"
do

    RGRP_PATH=${BIOM_PATH%.*}.${GROUP}.biom
    STRT_PATH=${BIOM_PATH%.*}.${GROUP}.str

    # regroup table

    humann_regroup_tables \
    -i $BIOM_PATH \
    -g $GROUP \
    -o $RGRP_PATH

    # split stratified tables

    humann_split_stratified_table \
    -i $RGRP_PATH \
    -o ${OUTPUT_DIR}/unstratified

done


echo "Processing complete. Output saved to $OUTPUT_DIR/$OUTPUT_NAME"