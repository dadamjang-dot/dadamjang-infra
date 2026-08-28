#!/usr/bin/env bash

set -uo pipefail

failures=0

expect_present() {
  local label="$1"
  local needle="$2"
  local file="$3"

  if grep -Fq -- "$needle" "$file"; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s\n' "$label"
    failures=$((failures + 1))
  fi
}

expect_absent() {
  local label="$1"
  local needle="$2"
  local file="$3"

  if grep -Fq -- "$needle" "$file"; then
    printf 'not ok - %s\n' "$label"
    failures=$((failures + 1))
  else
    printf 'ok - %s\n' "$label"
  fi
}

expect_count() {
  local label="$1"
  local needle="$2"
  local expected="$3"
  local file="$4"
  local actual

  actual=$(grep -Fc -- "$needle" "$file")
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

expect_absent "Docker build has no redundant standalone tsc" "pnpm exec tsc scripts/migrate.ts" docker/backend.Dockerfile
expect_present "Docker starts the emitted backend entrypoint" "node dist/scripts/migrate.js && node dist/src/main.js" docker/backend.Dockerfile
expect_present "e2e task starts the emitted backend entrypoint" 'command = ["node", "dist/src/main.js"]' terraform/e2e/application.tf

expect_present "deploy resolves the checked-out backend commit" 'sha=$(git -C backend rev-parse HEAD)' .github/workflows/api-deploy.yml
expect_count "deploy reuses the backend commit for every image reference" '${{ steps.backend-commit.outputs.sha }}' 3 .github/workflows/api-deploy.yml
expect_absent "deploy never tags backend images with the infra commit" '${{ github.sha }}' .github/workflows/api-deploy.yml

expect_present "deploy OIDC trust uses the staging environment subject" 'values   = ["repo:${var.github_repository}:environment:${var.environment}"]' terraform/staging/iam.tf
expect_absent "deploy OIDC trust does not use a branch subject" ':ref:refs/heads/' terraform/staging/iam.tf

expect_present "deploy tests provision PostgreSQL" "services:" .github/workflows/api-deploy.yml
expect_present "deploy PostgreSQL uses the integration database" "POSTGRES_DB: dadamjang_test" .github/workflows/api-deploy.yml
expect_present "deploy PostgreSQL exposes the integration port" "- 55432:5432" .github/workflows/api-deploy.yml

for key in \
  API_PUBLIC_BASE_URL \
  DADAMJANG_BO_URL \
  IDENTITY_CI_PEPPER \
  IDENTITY_INICIS_API_KEY \
  IDENTITY_INICIS_CALLBACK_BASE_URL \
  IDENTITY_INICIS_MID \
  IDENTITY_INICIS_SEED_IV; do
  expect_present "staging injects $key" "\"$key\"" terraform/staging/locals.tf
done

exit "$failures"
