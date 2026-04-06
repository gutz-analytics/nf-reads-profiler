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
docker buildx build --platform linux/arm64,linux/amd64 -t colinbrislawn/sra-tools-bash:3.2.1 --push sra-tools-bash
docker buildx build --platform linux/arm64 -t colinbrislawn/metaphlan:4.2.4 --push metaphlan
docker buildx build --platform linux/arm64 -t colinbrislawn/medi:0.2.1 --push medi
```

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

```
