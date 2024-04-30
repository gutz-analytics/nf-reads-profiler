
nextflow run main.nf     \
--az_location $AZURE_BATCH_LOCATION       \
--batch_name $AZURE_BATCH_ACCOUNT_NAME       \
--batch_key $AZURE_BATCH_ACCOUNT_KEY       \
--storage_name $AZURE_STORAGE_ACCOUNT_NAME       \
--storage_key $AZURE_STORAGE_ACCOUNT_KEY       \
--outdir "az://nextflow-analysis/workflows"     \
-w "az://nextflow-analysis/workflows/work" \
--input "az://nextflow-data/fetchngs/samplesheet/samplesheet.csv" \
-resume