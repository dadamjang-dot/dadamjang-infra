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

image_reference="$registry/$repository@$image_digest"
docker pull --platform linux/amd64 "$image_reference" >&2
printf '%s\n' \
  '44d98c294ac8c2afa502f7bdb2c65411df7d4879dad39cd5b4fbc8cf9c94059f  /app/retired-migrations/0005_catalog_demo_products.sql' \
  | docker run --rm --platform linux/amd64 --interactive --entrypoint sha256sum "$image_reference" -c - >&2

printf '%s\n' "$image_reference"
