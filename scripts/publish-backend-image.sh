#!/usr/bin/env bash

set -euo pipefail

registry="$1"
repository="$2"
image_tag="$3"
dockerfile="$4"
context="$5"
image="$registry/$repository:$image_tag"

if image_digest=$(aws ecr describe-images \
  --repository-name "$repository" \
  --image-ids "imageTag=$image_tag" \
  --query 'imageDetails[0].imageDigest' \
  --output text 2>&1); then
  printf 'Reusing immutable image %s (%s)\n' "$image" "$image_digest"
elif [[ "$image_digest" == *"ImageNotFoundException"* ]]; then
  docker build --file "$dockerfile" --tag "$image" "$context"
  docker push "$image"
else
  printf '%s\n' "$image_digest" >&2
  exit 1
fi
