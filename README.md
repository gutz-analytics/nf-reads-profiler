## Acknowledgement

This pipeline is based on the original [YAMP](https://github.com/alesssia/YAMP) repo. Modifications have been made to make use of our infrastrucutre more readily. If you're here for a more customizable and flexible pipeline, please consider taking a look at the original repo.

# nf-reads-profiler

## Usage

```{bash}
aws batch submit-job \
    --profile maf \
    --job-name nf-rp-1101-2 \
    --job-queue priority-maf-pipelines \
    --job-definition nextflow-production \
    --container-overrides command=fischbachlab/nf-reads-profiler,\
"--prefix","branch_metaphlan4",\
"--singleEnd","false",\
"--reads1","s3://dev-scratch/fastq/small/random_ncbi_reads_with_duplicated_and_contaminants_R1.fastq.gz",\
"--reads2","s3://dev-scratch/fastq/small/random_ncbi_reads_with_duplicated_and_contaminants_R2.fastq.gz"
```

### Cross account test

```bash
"--reads1","s3://czb-seqbot/fastqs/200817_NB501938_0185_AH23FNBGXG/MITI_Purification_Healthy/E8_SH0000236_0619-Cult-2-481_S22_R1_001.fastq.gz",\
"--reads2","s3://czb-seqbot/fastqs/200817_NB501938_0185_AH23FNBGXG/MITI_Purification_Healthy/E8_SH0000236_0619-Cult-2-481_S22_R2_001.fastq.gz"
```

## Local testing

Run the test profile (Docker, small data) in a persistent `screen` session so the pipeline survives SSH disconnects:

```bash
screen -S nf-test
nextflow run main.nf -profile test_medi
# Detach:   Ctrl+A  D
# Reattach: screen -r nf-test
# List:     screen -ls
```

To watch progress from another terminal while it runs:

```bash
tail -f .nextflow.log
```

See `CLAUDE.md` for full pipeline architecture, parameter reference, DB layout, and AWS Batch infra notes. That file is the primary onboarding doc for both humans and AI assistants working in this repo.

## Databases

Although the databases have been stored at the appropriate `/mnt/efs/databases` location mentioned in the config file. There might come a time when these need to be updated. Here is a quick view on how to do that.

### Metaphlan4 - [latest](http://cmprod1.cibio.unitn.it/biobakery4/metaphlan_databases/mpa_latest) database

In April 2026, that was `mpa_vJan25_CHOCOPhlAnSGB_202503`

33433 MB at 20 MB/sec takes about 30 minutes for the bt2l index files.
Then another 30 minutes for everything else and to decompress it.
**~1 h total**.

How long does it take to copy from S3, I wonder?

```sh
mkdir -p /home/ubuntu/disk_dbs/metaphlan_databases/vJan25

docker run --rm \
  -v /home/ubuntu/disk_dbs/metaphlan_databases/vJan25:/databases \
  colinbrislawn/metaphlan:4.2.4 \
  metaphlan --install \
    --nproc 4 \
    --db_dir /databases \
    --index mpa_vJan25_CHOCOPhlAnSGB_202503
# includes the .bt2l files for bowtie2 and the
# .nwk, .pkl, _VINFO.csv, and _VSG.fna files.
ls -alh /home/ubuntu/disk_dbs/metaphlan_databases/vJan25/
```

### Humann4

This requires 3 databases. We use the same `docker_container_humann4` as the pipeline.

TODO: benchmark this against copying from Mountpoint S3.

#### Chocophlan

```sh
echo "Untested"

mkdir -p /home/ubuntu/disk_dbs/chocophlan_v4_alpha
docker run --rm \
  -v /home/ubuntu/disk_dbs/chocophlan_v4_alpha:/databases \
  barbarahelena/humann:4.0.3 \
  humann_databases \
    --download chocophlan v4_alpha /databases
```

#### Uniref

```sh
echo "Untested"

mkdir -p /home/ubuntu/disk_dbs/uniref90_annotated_v4_alpha_ec_filtered
docker run --rm \
  -v /home/ubuntu/disk_dbs/uniref90_annotated_v4_alpha_ec_filtered:/databases \
  barbarahelena/humann:4.0.3 \
  humann_databases \
    --download uniref uniref90_annotated_v4_alpha_ec_filtered /databases
```

#### Utility Mapping Databases

```sh
echo "Untested"

mkdir -p /home/ubuntu/disk_dbs/full_mapping_v4_alpha
docker run --rm \
  -v /home/ubuntu/disk_dbs/full_mapping_v4_alpha:/databases \
  barbarahelena/humann:4.0.3 \
  humann_databases \
    --download utility_mapping v4_alpha /databases
```
