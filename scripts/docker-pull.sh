#!/usr/bin/env bash
#
# Pulls a Docker Hub official image, pinned by digest, and prints the
# reference that was pulled (to pass to `docker run`).
#
#   image="$(bash scripts/docker-pull.sh "alpine:3.22@sha256:...")"
#
# Unauthenticated pulls from Docker Hub are rate limited, which fails the
# build. The image is first pulled from registries that mirror the official
# images, then from Docker Hub, retrying the whole list with a backoff.
# The digest pin makes Docker verify the content whichever registry serves it.
#
# Kept bash 3.2 compatible -- see scripts/build-ffmpeg.sh.

set -eo pipefail

IMAGE="$1"
case "$IMAGE" in
  *@sha256:*) ;;
  *) echo "The image must be pinned by digest: $IMAGE" >&2; exit 1 ;;
esac

REFERENCES="mirror.gcr.io/library/$IMAGE public.ecr.aws/docker/library/$IMAGE docker.io/library/$IMAGE"
MAX_ATTEMPTS=5

attempt=1
while true; do
  for reference in $REFERENCES; do
    # docker pull reports progress on stdout; keep stdout for the result
    if docker pull --quiet "$reference" >&2; then
      echo "$reference"
      exit 0
    fi
    echo "Failed to pull $reference (attempt $attempt/$MAX_ATTEMPTS)" >&2
  done

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "Failed to pull $IMAGE after $MAX_ATTEMPTS attempts" >&2
    exit 1
  fi

  sleep $((10 * attempt))
  attempt=$((attempt + 1))
done
