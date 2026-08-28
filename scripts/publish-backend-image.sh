#!/usr/bin/env bash

set -euo pipefail

registry="$1"
repository="$2"
image_tag="$3"
dockerfile="$4"
context="$5"
image="$registry/$repository:$image_tag"
error_file=$(mktemp)
trap 'rm -f "$error_file"' EXIT

if aws ecr describe-images \
  --repository-name "$repository" \
  --image-ids "imageTag=$image_tag" \
  --query 'imageDetails[0].imageDigest' \
  --output text >/dev/null 2>"$error_file"; then
  printf 'Reusing immutable image %s\n' "$image" >&2
elif grep -q 'ImageNotFoundException' "$error_file"; then
  docker build --platform linux/amd64 --file "$dockerfile" --tag "$image" "$context" >&2
  docker push "$image" >&2
else
  cat "$error_file" >&2
  exit 1
fi

image_digest=$(aws ecr describe-images \
  --repository-name "$repository" \
  --image-ids "imageTag=$image_tag" \
  --query 'imageDetails[0].imageDigest' \
  --output text)

if [[ ! "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  printf 'ECR returned an invalid image digest: %s\n' "$image_digest" >&2
  exit 1
fi

printf '%s@%s\n' "$registry/$repository" "$image_digest"
