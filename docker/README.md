# Docker readme

## Setup

```sh
docker login
# I opened the web browser and logged in with GitHub

# Set up multiplatform builds, see
# https://forums.docker.com/t/error-multiple-platforms-feature-is-currently-not-supported-for-docker-driver/124811/12
docker buildx ls
docker buildx create --name multiarch --driver docker-container --use
docker buildx ls
```

## Buildx

Note that the final argument is the path to the folder with the Dockerfile, not the name of the image. The name of the image is set with the -t flag.

```sh
cd docker

# Build and push multi-arch (amd64 + arm64)
docker buildx build --platform linux/amd64,linux/arm64 -t colinbrislawn/aws-cli-bash:2 --push aws-cli-bash
docker buildx build --platform linux/amd64,linux/arm64 -t colinbrislawn/sra-tools-bash:3.0.7 --push sra-tools-bash
docker buildx build --platform linux/arm64 -t colinbrislawn/hostile:2.0.2 --push hostile
docker buildx build --platform linux/arm64 -t colinbrislawn/metaphlan:4.2.4 --push metaphlan
docker buildx build --platform linux/arm64 -t colinbrislawn/medi:0.2.1 --push medi
```

## hostile index (one-time download)

hostile downloads its human reference index separately from the image.
Run this once to cache the bowtie2 index (paired-end short reads) to `~/disk_dbs/hostile/`:

```sh
docker run --rm \
  -v ~/disk_dbs/hostile:/root/.local/share/hostile \
  colinbrislawn/hostile:2.0.2 \
  hostile index fetch --bowtie2
```

Then pass `--airplane` on all subsequent `hostile clean` runs and mount the same directory:

```sh
docker run --rm \
  -v ~/disk_dbs/hostile:/root/.local/share/hostile \
  -v /path/to/data:/data -v /path/to/out:/out \
  colinbrislawn/hostile:2.0.2 \
  hostile clean \
    --fastq1 /data/R1.fastq.gz --fastq2 /data/R2.fastq.gz \
    -o /out --airplane --threads 4
```

On AWS workers, mount `/mnt/dbs/hostile` instead and include the index in the `aws s3 sync`.

## View images we can give to Nextlow

```sh
docker search colinbrislawn
```

## Extra!

```sh
# View all local images on this machine
docker image ls

# Remove a local image
# be specific with REPOSITORY:TAG
docker image rm hello-world:latest
docker image rm lightweightlabware/aws-cli-bash:ubuntu
docker image rm amazon/aws-cli

```
