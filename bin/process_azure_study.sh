#!/usr/bin/env bash

# Function to display help message
show_help() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo "A script to process study data."
    echo
    echo "Options:"
    echo "  -a, --account    ACCOUNT       Azure storage account name."
    echo "  -c, --container  CONTAINER     Azure storage container name."
    echo "  -s, --study      STUDY         Study name or identifier."
    echo "  -i, --input-dir  INPUT_DIR     Directory containing input data."
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
        -a|--account)
            ACCOUNT="$2"
            shift 2
            ;;
        -c|--container)
            CONTAINER="$2"
            shift 2
            ;;
        -s|--study)
            STUDY="$2"
            shift 2
            ;;
        -i|--input-dir)
            INPUT_DIR="$2"
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
if [ -z "$ACCOUNT" ] || [ -z "$CONTAINER" ] || [ -z "$STUDY" ] || [ -z "$INPUT_DIR" ]; then
    echo "Error: Missing required arguments."
    show_help
    exit 1
fi

# Example processing command (replace with actual processing logic)
echo "Processing study data..."


STUDY_DIR="https://${ACCOUNT}.blob.core.windwos.net/${CONTAINER}/${INPUT_DIR}/${STUDY}"
GENEFAM="${STUDY_DIR}/function/${STUDY}_genefamilies_combined.tsv"
METAPHLAN="${STUDY_DIR}/taxa/${STUDY}_bugs_list_combined.tsv"
echo "Azure Account: $ACCOUNT"
echo "Container Name: $CONTAINER"
echo "Study: $STUDY"
echo "Input Directory: $INPUT_DIR"
echo "Genefamily table: $GENEFAM"
echo "Metaphlan table: $METAPHLAN"

# make temp dir 
# <!-- from https://stackoverflow.com/a/34676160

# the directory of the script
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# the temp directory used, within $DIR
# omit the -p parameter to create a temporal directory in the default location
WORK_DIR=`mktemp -d -p "$DIR"`

# check if tmp dir was created
if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
  echo "Could not create temp dir"
  exit 1
fi

# deletes the temp directory
function cleanup {      
  rm -rf "$WORK_DIR"
  echo "Deleted temp working directory $WORK_DIR"
}

# register the cleanup function to be called on the EXIT signal
trap cleanup EXIT

# implementation of script starts here

# !-->

# az copy input biom table

# workflows/analysis_20240508/PRJEB46777/function/PRJEB46777_genefamilies_combined.tsv
azcopy copy $GENEFAM ${} \
${WORK_DIR}/${STUDY}_genefamilies_combined.tsv

# az copy input metaphlann table

# workflows/analysis_20240508/PRJEB46777/taxa/PRJEB46777_bugs_list_combined.tsv
azcopy copy $METAPHLAN ${} \
${WORK_DIR}/${STUDY}_bugs_list_combined.tsv


# run process_humann_tables.sh
process_humann_tables.sh \
-i ${WORK_DIR}/${STUDY}_genefamilies_combined.tsv \
-o ${WORK_DIR}/${STUDY}_processed_tables \
-n ${STUDY}


# run biom convert for metaphlan
biom convert \
    --input-fp ${WORK_DIR}/${STUDY}_bugs_list_combined.tsv \
    --output-fp ${WORK_DIR}/${STUDY}_processed_tables/${STUDY}_bugs_list_combined.biom \
    --table-type 'Taxon table' \
    --to-hdf5

# copy outputs to az blob
 azcopy cp \
 "${WORK_DIR}/${STUDY}_processed_tables" \
 "${STUDY_DIR}/${STUDY}_processed_tables" \
 --recursive=true 

