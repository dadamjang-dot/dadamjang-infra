#!/usr/bin/env ruby

require "fileutils"
require "digest"
require "json"
require "open3"
require "set"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/api-deploy.yml"))
infra_ci = YAML.load_file(File.join(root, ".github/workflows/infra-ci.yml"))
terraform_apply = YAML.load_file(File.join(root, ".github/workflows/terraform-apply.yml"))
compose = YAML.load_file(File.join(root, "docker-compose.yml"))
infra_ci_triggers = infra_ci["on"] || infra_ci.fetch(true)
jobs = workflow.fetch("jobs")
test_job = jobs.fetch("test")
deploy_job = jobs.fetch("deploy")
failures = []
runtime_secret_keys = Set.new(%w[
  API_PUBLIC_BASE_URL
  CLIENT_URL
  CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL
  CLOUDFLARE_R2_ACCESS_KEY_ID
  CLOUDFLARE_R2_BUCKET
  CLOUDFLARE_R2_ENDPOINT
  CLOUDFLARE_R2_PENDING_BUCKET
  CLOUDFLARE_R2_PUBLIC_BASE_URL
  CLOUDFLARE_R2_SECRET_ACCESS_KEY
  DADAMJANG_BO_URL
  EMAIL_CODE_PEPPER
  IDENTITY_CI_PEPPER
  IDENTITY_INICIS_API_KEY
  IDENTITY_INICIS_CALLBACK_BASE_URL
  IDENTITY_INICIS_MID
  IDENTITY_INICIS_SEED_IV
  JWT_ACCESS_TOKEN_EXP
  JWT_ACCESS_TOKEN_SECRET
  JWT_REFRESH_TOKEN_EXP
  JWT_REFRESH_TOKEN_SECRET
  KAKAO_CALLBACK_URL
  KAKAO_CLIENT_ID
  RESEND_API_KEY
  RESEND_FROM_EMAIL
  SENTRY_DSN
])

assert = lambda do |condition, message|
  raise message unless condition
end

check = lambda do |name, &block|
  block.call
  puts "ok - #{name}"
rescue StandardError => error
  failures << name
  warn "not ok - #{name}: #{error.message}"
end

step_named = lambda do |job, name|
  job.fetch("steps").find { |step| step["name"] == name } || raise("missing step #{name}")
end

uses_action = lambda do |step, action|
  step["uses"].to_s.start_with?("#{action}@")
end

write_executable = lambda do |path, body|
  File.write(path, body)
  FileUtils.chmod(0o755, path)
end

docker_instructions = lambda do
  File.read(File.join(root, "docker/backend.Dockerfile"))
    .gsub(/ ?\\\n\s*/, " ")
    .lines(chomp: true)
    .map(&:strip)
    .reject { |line| line.empty? || line.start_with?("#") }
end

check.call("Docker build and runtime use backend build outputs") do
  instructions = docker_instructions.call
  assert.call(instructions.none? { |line| line.include?("tsc scripts/migrate.ts") }, "standalone tsc remains")
  assert.call(
    instructions.include?('CMD ["sh", "-c", "node dist/scripts/migrate.js && exec node dist/src/main.js"]'),
    "runtime command does not migrate before handing PID 1 to Node",
  )
  assert.call(
    instructions.include?("COPY --from=build --chown=node:node /app/retired-migrations ./retired-migrations"),
    "runtime image omits retired migration history",
  )
end

check.call("Docker runtime ships the checksum-verified AWS RDS CA bundle") do
  instructions = docker_instructions.call
  stages = instructions.slice_before { |line| line.match?(/\AFROM\s/i) }.to_a
  runtime_stage = stages.last.join("\n")
  bundle_url = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
  bundle_checksum = "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3"
  build_bundle_path = "/tmp/aws-rds-global-bundle.pem"
  runtime_bundle_path = "/etc/ssl/certs/aws-rds-global-bundle.pem"
  download_stage = stages[0...-1].find { |stage| stage.join("\n").include?(bundle_url) }

  assert.call(download_stage, "build stages do not fetch the official AWS RDS global bundle")
  build_stage = download_stage.join("\n")
  checksum_instruction = download_stage.find { |line| line.include?("sha256sum -c -") }
  copy_command = "COPY --from=build #{build_bundle_path} #{runtime_bundle_path}"
  assert.call(build_stage.include?(bundle_url), "AWS RDS bundle is not downloaded from the exact official URL")
  assert.call(!build_stage.match?(/\b(?:curl|wget)\b|\bapk\s+add\b/), "build stage installs mutable download tooling")
  assert.call(checksum_instruction&.start_with?("RUN echo "), "AWS RDS checksum is not an isolated executable build step")
  assert.call(runtime_stage.lines(chomp: true).include?(copy_command), "runtime image does not copy the verified build-stage AWS RDS bundle")
  assert.call(!runtime_stage.match?(/\b(?:curl|wget)\b|\bapk\s+add\b/), "runtime stage installs download tooling")

  Dir.mktmpdir("aws-rds-bundle-checksum") do |directory|
    rotated_bundle = File.join(directory, "aws-rds-global-bundle.pem")
    File.write(rotated_bundle, "rotated AWS RDS bundle bytes\n")
    command = checksum_instruction.delete_prefix("RUN ").gsub(build_bundle_path, rotated_bundle)
    _, _, status = Open3.capture3("bash", "-c", command, chdir: directory)
    assert.call(!status.success?, "checksum build step accepted rotated AWS RDS bundle bytes")
  end
end

check.call("Docker image identity pins the amd64 Node base") do
  instructions = docker_instructions.call
  base = "node:22-alpine@sha256:76789712cd1ae89a1225eac9077010d68987a423588042dac30446f502f1858c"
  from_images = instructions.map { |line| line[/\AFROM\s+(\S+)/, 1] }.compact
  assert.call(from_images == [base, base], "Node build stages do not share the verified linux/amd64 digest")
  healthcheck = instructions.find { |line| line.start_with?("HEALTHCHECK ") }
  assert.call(healthcheck&.include?("node") && healthcheck.include?("/health/ready"), "runtime healthcheck does not use built-in Node readiness")
end

check.call("local development services use reviewed immutable images") do
  expected = {
    "postgres" => "postgres:16.15-alpine3.24@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685",
    "redis" => "redis:7.4.9-alpine3.21@sha256:6ab0b6e7381779332f97b8ca76193e45b0756f38d4c0dcda72dbb3c32061ab99",
    "minio" => "pgsty/silo:RELEASE.2026-08-06T00-00-00Z@sha256:29a498b24669cae1fed11c1a2fb2b3d73c68829a0a9c0b14e71b386671d38fac",
    "mailpit" => "axllent/mailpit:v1.31.0@sha256:c96991d9bef73594c246d89ca81411d4e916f03e76a7d2d72fa2ab5dd3c9ce24",
  }
  actual = compose.fetch("services").to_h { |name, service| [name, service.fetch("image")] }
  assert.call(actual == expected, "unreviewed local service images: #{actual}")
end

check.call("infra CI watches release behavior") do
  required_paths = Set.new([".env.example", "scripts/**"])
  %w[pull_request push].each do |event|
    configured_paths = infra_ci_triggers.fetch(event).fetch("paths").to_set
    missing_paths = required_paths - configured_paths
    assert.call(missing_paths.empty?, "#{event} omits #{missing_paths.to_a.join(", ")}")
  end
end

check.call("API workflow scopes OIDC permission to deploy") do
  assert.call(workflow.fetch("permissions") == { "contents" => "read" }, "workflow-wide permissions can mint OIDC tokens")
  assert.call(!test_job.fetch("permissions", {}).key?("id-token"), "test job can mint OIDC tokens")
  assert.call(
    deploy_job.fetch("permissions") == { "contents" => "read", "id-token" => "write" },
    "deploy job lacks exact OIDC permissions",
  )
end

check.call("API workflow resolves event-specific backend refs") do
  triggers = workflow["on"] || workflow.fetch(true)
  manual_input = triggers.fetch("workflow_dispatch").fetch("inputs").fetch("backend_ref")
  assert.call(manual_input.fetch("required"), "manual backend ref is optional")
  assert.call(manual_input.fetch("type") == "string", "manual backend ref is not an explicit string")
  assert.call(manual_input.fetch("default") == "main", "manual backend ref default is not explicit")
  resolver = step_named.call(test_job, "Resolve backend ref")
  assert.call(resolver.fetch("id") == "backend-ref", "resolved backend ref is not captured")
  backend_checkout = test_job.fetch("steps").find do |step|
    uses_action.call(step, "actions/checkout") && step.dig("with", "repository") == "dadamjang-dot/dadamjang-be"
  end || raise("missing backend checkout")
  assert.call(backend_checkout.dig("with", "ref") == "${{ steps.backend-ref.outputs.backend_ref }}", "backend checkout bypasses the validated ref")

  resolve = lambda do |event_name:, repository_ref:, manual_ref:|
    Dir.mktmpdir("backend-ref") do |directory|
      github_output = File.join(directory, "github-output")
      _, error, status = Open3.capture3(
        {
          "EVENT_NAME" => event_name,
          "GITHUB_OUTPUT" => github_output,
          "REPOSITORY_DISPATCH_REF" => repository_ref,
          "WORKFLOW_DISPATCH_REF" => manual_ref,
        },
        "bash", "-eu", "-c", resolver.fetch("run"),
        chdir: root,
      )
      values = File.exist?(github_output) ? File.readlines(github_output, chomp: true).to_h { |line| line.split("=", 2) } : {}
      [values["backend_ref"], error, status]
    end
  end

  repository_sha = "a" * 40
  resolved, error, status = resolve.call(event_name: "repository_dispatch", repository_ref: repository_sha, manual_ref: "main")
  assert.call(status.success?, error)
  assert.call(resolved == repository_sha, "repository dispatch did not preserve the exact commit")
  ["", "main", "a" * 39, "g" * 40].each do |invalid_ref|
    _, _, invalid_status = resolve.call(event_name: "repository_dispatch", repository_ref: invalid_ref, manual_ref: "main")
    assert.call(!invalid_status.success?, "repository dispatch accepted #{invalid_ref.inspect}")
  end

  resolved, error, status = resolve.call(event_name: "workflow_dispatch", repository_ref: repository_sha, manual_ref: "release/manual-ref")
  assert.call(status.success?, error)
  assert.call(resolved == "release/manual-ref", "manual dispatch did not preserve its explicit ref")
  ["", "   "].each do |invalid_ref|
    _, _, invalid_status = resolve.call(event_name: "workflow_dispatch", repository_ref: repository_sha, manual_ref: invalid_ref)
    assert.call(!invalid_status.success?, "manual dispatch accepted #{invalid_ref.inspect}")
  end
end

check.call("infra CI runs native contracts for staging and e2e") do
  validate = infra_ci.fetch("jobs").fetch("validate")
  assert.call(step_named.call(validate, "Test Terraform release contracts").fetch("run") == "terraform -chdir=terraform/staging test", "staging native contracts are not run")
  assert.call(step_named.call(validate, "Test e2e Terraform release contracts").fetch("run") == "terraform -chdir=terraform/e2e test", "e2e native contracts are not run")
end

check.call("Terraform roots select remote state for partial backend configuration") do
  version_output, version_error, version_status = Open3.capture3("terraform", "version", "-json", chdir: root)
  assert.call(version_status.success?, version_error)
  terraform_platform = JSON.parse(version_output).fetch("platform")

  %w[staging e2e].each do |environment|
    Dir.mktmpdir("#{environment}-backend") do |directory|
      Dir.glob(File.join(root, "terraform/#{environment}/*.tf")).each do |path|
        FileUtils.cp(path, directory)
      end
      backend_config = File.join(directory, "backend.hcl")
      plugin_directory = File.join(directory, "plugins")
      provider_directory = File.join(
        plugin_directory,
        "registry.terraform.io/hashicorp/aws/6.0.0/#{terraform_platform}",
      )
      FileUtils.mkdir_p(provider_directory)
      write_executable.call(
        File.join(provider_directory, "terraform-provider-aws_v6.0.0_x5"),
        "#!/bin/sh\nexit 1\n",
      )
      cloudflare_provider_directory = File.join(
        plugin_directory,
        "registry.terraform.io/cloudflare/cloudflare/5.24.0/#{terraform_platform}",
      )
      FileUtils.mkdir_p(cloudflare_provider_directory)
      write_executable.call(
        File.join(cloudflare_provider_directory, "terraform-provider-cloudflare_v5.24.0_x5"),
        "#!/bin/sh\nexit 1\n",
      )
      File.write(backend_config, <<~HCL)
        hostname     = "terraform.invalid"
        organization = "example"

        workspaces {
          name = "dadamjang-#{environment}"
        }
      HCL
      stdout, stderr, status = Open3.capture3(
        {
          "ALL_PROXY" => "http://127.0.0.1:1",
          "HTTP_PROXY" => "http://127.0.0.1:1",
          "HTTPS_PROXY" => "http://127.0.0.1:1",
          "NO_PROXY" => "",
          "TF_DATA_DIR" => File.join(directory, "data"),
          "all_proxy" => "http://127.0.0.1:1",
          "http_proxy" => "http://127.0.0.1:1",
          "https_proxy" => "http://127.0.0.1:1",
          "no_proxy" => "",
        },
        "terraform",
        "init",
        "-input=false",
        "-get=false",
        "-backend-config=backend.hcl",
        "-plugin-dir=#{plugin_directory}",
        "-no-color",
        chdir: directory,
      )
      output = stdout + stderr
      assert.call(!status.success?, "#{environment} unexpectedly initialized against the controlled endpoint")
      assert.call(
        output.include?("Failed to request discovery document"),
        "#{environment} did not reach the expected backend discovery failure:\n#{output}",
      )
      assert.call(output.include?("https://terraform.invalid/.well-known/terraform.json"), "#{environment} contacted an unexpected backend endpoint")
      assert.call(output.include?("127.0.0.1:1"), "#{environment} backend discovery escaped the loopback proxy")
      assert.call(!output.include?("Invalid backend configuration argument"), "#{environment} rejected a supported backend argument")
      assert.call(!output.include?("Unsupported argument"), "#{environment} rejected the supported backend configuration")
      assert.call(!output.include?("Missing backend configuration"), "#{environment} ignores its remote backend configuration")
    end
  end
end

check.call("Terraform backend contracts exclude unsupported execution settings") do
  [
    ".github/workflows/api-deploy.yml",
    ".github/workflows/terraform-apply.yml",
  ].each do |path|
    contents = File.read(File.join(root, path))
    assert.call(!contents.match?(/\boperations\b/i), "#{path} includes the unsupported remote backend operations key")
  end
end

check.call("HCP Terraform credentials stay outside backend configuration and plans") do
  terraform_job = terraform_apply.fetch("jobs").fetch("terraform")
  terraform_jobs = {
    ".github/workflows/api-deploy.yml" => [deploy_job, "${{ secrets.HCP_TERRAFORM_OUTPUT_TOKEN }}"],
    ".github/workflows/terraform-apply.yml" => [terraform_job, "${{ secrets.HCP_TERRAFORM_PLAN_TOKEN }}"],
  }
  hcp_token_name = /HCP_TERRAFORM(?:_(?:PLAN|OUTPUT))?_TOKEN/

  terraform_jobs.each do |path, (job, token_secret)|
    setup_steps = job.fetch("steps").select { |step| uses_action.call(step, "hashicorp/setup-terraform") }
    assert.call(setup_steps.length == 1, "#{path} must have exactly one Terraform setup step")
    setup = setup_steps.first
    assert.call(setup.dig("with", "cli_config_credentials_hostname") == "app.terraform.io", "#{path} configures Terraform credentials for the wrong hostname")
    assert.call(setup.dig("with", "cli_config_credentials_token") == token_secret, "#{path} injects the wrong HCP token")
    assert.call(JSON.generate(job).scan(hcp_token_name).length == 1, "#{path} does not use exactly one isolated HCP token reference")
    backend_step = step_named.call(job, "Write Terraform backend configuration")
    backend_env = job.fetch("env", {}).merge(backend_step.fetch("env", {}))
    assert.call(backend_env.fetch("TF_BACKEND_CONFIG") == "${{ secrets.TF_BACKEND_CONFIG }}", "#{path} does not keep backend metadata in its dedicated protected input")
    run_commands = job.fetch("steps").map { |step| step["run"] }.compact.join("\n")
    assert.call(!run_commands.match?(hcp_token_name), "#{path} exposes an HCP token to backend configuration, commands, or logs")
  end

  assert.call(terraform_job.dig("environment", "name") == "staging", "Terraform plan job is missing the protected staging environment")
  tfplan_artifacts = terraform_job.fetch("steps").select do |step|
    uses_action.call(step, "actions/upload-artifact") && step.dig("with", "path").to_s.match?(/(?:^|[\/\\])[^\n]*\.tfplan(?:$|\n)/)
  end
  assert.call(tfplan_artifacts.empty?, "Terraform workflow uploads a tfplan artifact that could retain backend data")
end

check.call("staging ECS service waits for the HTTPS listener") do
  Dir.mktmpdir("staging-graph") do |directory|
    File.write(File.join(directory, "main.tf"), <<~HCL)
      module "staging" {
        source = #{JSON.generate(File.join(root, "terraform/staging"))}

        acm_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/example"
        api_hostname        = "api.staging.example.test"
        cloudflare_account_id          = "00000000000000000000000000000000"
        cloudflare_r2_final_bucket_name = "dadamjang-staging-final"
      }
    HCL
    provider_directory = if ENV["TF_DATA_DIR"]
      File.join(ENV.fetch("TF_DATA_DIR"), "providers")
    else
      File.join(root, "terraform/staging/.terraform/providers")
    end
    terraform_data = File.join(directory, ".terraform-data")
    _, init_error, init_status = Open3.capture3(
      { "TF_DATA_DIR" => terraform_data },
      "terraform", "-chdir=#{directory}", "init", "-backend=false", "-input=false", "-plugin-dir=#{provider_directory}",
      chdir: root,
    )
    assert.call(init_status.success?, init_error)
    graph, error, status = Open3.capture3(
      { "TF_DATA_DIR" => terraform_data },
      "terraform", "-chdir=#{directory}", "graph", "-type=plan",
      chdir: root,
    )
    assert.call(status.success?, error)
    edges = graph.lines.map { |line| line.match(/^\s*"([^"]+)" -> "([^"]+)"/)&.captures }.compact
    assert.call(
      edges.include?(["[root] module.staging.aws_ecs_service.api (expand)", "[root] module.staging.aws_lb_listener.https (expand)"]),
      "staging ECS service does not depend on the HTTPS listener",
    )
  end
end

check.call("privileged workflows execute only commit-pinned actions") do
  {
    ".github/workflows/api-deploy.yml" => workflow,
    ".github/workflows/infra-ci.yml" => infra_ci,
    ".github/workflows/terraform-apply.yml" => terraform_apply,
  }.each do |path, definition|
    mutable = definition.fetch("jobs").values.flat_map { |job| job.fetch("steps") }
      .map { |step| step["uses"] }
      .compact
      .reject { |uses| uses.match?(%r{\A[^@\s]+@[0-9a-f]{40}\z}) }
    assert.call(mutable.empty?, "#{path} has mutable action refs: #{mutable.join(", ")}")
  end
end

check.call("workflows use the reviewed Terraform CLI") do
  [workflow, infra_ci, terraform_apply].each do |definition|
    setup_steps = definition.fetch("jobs").values.flat_map { |job| job.fetch("steps") }
      .select { |step| uses_action.call(step, "hashicorp/setup-terraform") }
    assert.call(!setup_steps.empty?, "workflow does not install Terraform")
    setup_steps.each do |step|
      assert.call(step.dig("with", "terraform_version").to_s == "1.15.7", "workflow does not pin Terraform 1.15.7")
    end
  end
end

check.call("test job owns the PostgreSQL integration service") do
  postgres = test_job.fetch("services").fetch("postgres")
  assert.call(
    postgres.fetch("image") == "postgres:16.15-alpine3.24@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685",
    "wrong PostgreSQL image",
  )
  assert.call(postgres.fetch("env").fetch("POSTGRES_DB") == "dadamjang_test", "wrong integration database")
  assert.call(postgres.fetch("ports") == ["55432:5432"], "wrong integration port")
  assert.call(postgres.fetch("options").include?("pg_isready -U postgres -d dadamjang_test"), "missing health check")
  assert.call(deploy_job["services"].nil?, "PostgreSQL service is attached to deploy")
end

check.call("test job resolves the immutable release identity") do
  outputs = test_job.fetch("outputs")
  assert.call(outputs.fetch("backend_sha") == "${{ steps.release.outputs.backend_sha }}", "backend SHA is not a job output")
  assert.call(outputs.fetch("image_tag") == "${{ steps.release.outputs.image_tag }}", "image tag is not a job output")
  release_step = step_named.call(test_job, "Resolve release identity")
  assert.call(release_step.fetch("id") == "release", "release step id changed")

  Dir.mktmpdir("release-identity") do |directory|
    backend = File.join(directory, "backend")
    infra = File.join(directory, "infra")
    FileUtils.mkdir_p(File.join(infra, "docker"))
    FileUtils.mkdir_p(backend)
    File.write(File.join(backend, "package.json"), "{}\n")
    File.write(File.join(infra, "docker/backend.Dockerfile"), "FROM scratch\n")
    [[backend, "backend"], [infra, "infra"]].each do |repository, name|
      system("git", "-C", repository, "init", "-q", exception: true)
      system("git", "-C", repository, "add", ".", exception: true)
      system(
        "git", "-C", repository, "-c", "user.name=contract", "-c", "user.email=contract@example.test",
        "commit", "-qm", name, exception: true,
      )
    end
    github_output = File.join(directory, "github-output")
    _, stderr, status = Open3.capture3(
      { "GITHUB_OUTPUT" => github_output }, "bash", "-c", release_step.fetch("run"), chdir: directory,
    )
    assert.call(status.success?, stderr)
    values = File.readlines(github_output, chomp: true).to_h { |line| line.split("=", 2) }
    backend_sha = `git -C #{backend} rev-parse HEAD`.strip
    dockerfile_sha = `git -C #{infra} hash-object docker/backend.Dockerfile`.strip
    assert.call(values.fetch("backend_sha") == backend_sha, "release step did not resolve tested backend SHA")
    assert.call(
      values.fetch("image_tag") == "backend-#{backend_sha}-dockerfile-#{dockerfile_sha}",
      "image tag does not bind backend and Dockerfile identities",
    )
  end
end

check.call("deploy consumes only the tested release identity") do
  assert.call(deploy_job.fetch("needs") == "test", "deploy does not depend on test")
  assert.call(deploy_job.fetch("concurrency") == { "group" => "staging-api-deploy", "cancel-in-progress" => false }, "deploy can be canceled mid-release")
  assert.call(deploy_job.dig("environment", "name") == "staging", "staging approval is missing")
  backend_checkouts = deploy_job.fetch("steps").select do |step|
    uses_action.call(step, "actions/checkout") && step.dig("with", "repository") == "dadamjang-dot/dadamjang-be"
  end
  assert.call(backend_checkouts.length == 1, "deploy must have exactly one backend checkout")
  assert.call(
    backend_checkouts.all? { |step| step.dig("with", "ref") == "${{ needs.test.outputs.backend_sha }}" },
    "deploy checkout is mutable",
  )
  assert.call(deploy_job.fetch("env").keys.none? { |key| key.include?("BACKEND_REF") }, "deploy still accepts a mutable ref")
  deploy_definition = JSON.generate(deploy_job)
  assert.call(!deploy_definition.include?("github.sha"), "deploy uses the infra SHA as backend identity")
  assert.call(!deploy_definition.include?("rev-parse"), "deploy re-resolves the backend commit")
  publish = step_named.call(deploy_job, "Build or reuse immutable image")
  assert.call(publish.fetch("id") == "image", "published digest reference is not captured")
  assert.call(publish.dig("env", "IMAGE_TAG") == "${{ needs.test.outputs.image_tag }}", "publish tag is not test output")
  assert.call(
    publish.fetch("run").start_with?("bash infra/scripts/publish-backend-image.sh "),
    "workflow does not invoke the image publisher through bash",
  )
  assert.call(
    deploy_job.fetch("steps").none? { |step| step["uses"].to_s.start_with?("aws-actions/amazon-ecs-render-task-definition@") },
    "an action can mutate the reviewed task definition after preparation",
  )
  prepare = step_named.call(deploy_job, "Prepare reviewed ECS task definition")
  assert.call(prepare.dig("env", "IMAGE_REFERENCE") == "${{ steps.image.outputs.reference }}", "prepared image is not the tested digest")
  assert.call(
    prepare.dig("env", "SENTRY_RELEASE") == "${{ needs.test.outputs.image_tag }}",
    "prepared Sentry release is not the tested immutable image tag",
  )
end

check.call("image publication resolves an amd64 ECR digest after push") do
  Dir.mktmpdir("publish-image") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    docker_log = File.join(directory, "docker.log")
    write_executable.call(File.join(fake_bin, "aws"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
      if [[ "$FAKE_ECR_RESULT" == "denied" ]]; then
        printf '%s\n' 'AccessDeniedException: denied' >&2
        exit 255
      fi
      if [[ "$FAKE_ECR_RESULT" == "missing" && ! -f "$FAKE_DOCKER_LOG" ]]; then
        printf '%s\n' 'ImageNotFoundException: missing' >&2
        exit 254
      fi
      printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    SH
    write_executable.call(File.join(fake_bin, "docker"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
      if [[ "$1" == "run" ]]; then
        cat > "$FAKE_CHECKSUM_INPUT"
        [[ "$FAKE_IMAGE_CHECKSUM" != "invalid" ]] || exit 1
      fi
      printf '%s\n' 'docker progress'
    SH
    base_env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_AWS_LOG" => File.join(directory, "aws.log"),
      "FAKE_CHECKSUM_INPUT" => File.join(directory, "checksum-input"),
      "FAKE_DOCKER_LOG" => docker_log,
    }
    command = [
      "bash", File.join(root, "scripts/publish-backend-image.sh"), "registry.example", "api", "release-tag",
      "infra/docker/backend.Dockerfile", "backend",
    ]

    stdout, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "existing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(stdout.strip == "registry.example/api@sha256:#{"a" * 64}", "existing tag did not resolve to a digest reference")
    immutable_reference = "registry.example/api@sha256:#{"a" * 64}"
    expected_verification = [
      "pull --platform linux/amd64 #{immutable_reference}",
      "run --rm --platform linux/amd64 --interactive --entrypoint sha256sum #{immutable_reference} -c -",
    ]
    assert.call(File.exist?(docker_log), "existing image digest was not pulled and verified")
    assert.call(File.readlines(docker_log, chomp: true) == expected_verification, "existing image was not verified by digest")
    assert.call(
      File.read(base_env.fetch("FAKE_CHECKSUM_INPUT")) ==
        "44d98c294ac8c2afa502f7bdb2c65411df7d4879dad39cd5b4fbc8cf9c94059f  /app/retired-migrations/0005_catalog_demo_products.sql\n",
      "runtime verification does not enforce the historical retired migration checksum",
    )

    FileUtils.rm_f(docker_log)
    stdout, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "missing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(stdout.strip == "registry.example/api@sha256:#{"a" * 64}", "pushed tag did not resolve to a digest reference")
    assert.call(
      File.readlines(docker_log, chomp: true) == [
        "build --platform linux/amd64 --file infra/docker/backend.Dockerfile --tag registry.example/api:release-tag backend",
        "push registry.example/api:release-tag",
      ] + expected_verification,
      "missing image did not build and push once",
    )

    FileUtils.rm_f(docker_log)
    _, _, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "denied"), *command, chdir: root)
    assert.call(!status.success?, "unexpected ECR error was treated as a missing image")
    assert.call(!File.exist?(docker_log), "unexpected ECR error triggered Docker")

    stdout, _, status = Open3.capture3(
      base_env.merge("FAKE_ECR_RESULT" => "existing", "FAKE_IMAGE_CHECKSUM" => "invalid"),
      *command,
      chdir: root,
    )
    assert.call(!status.success?, "image with missing or changed retired migration was accepted")
    assert.call(stdout.empty?, "unverified image reference was emitted")
  end
end

check.call("deploy wires the tested digest into canonical task preparation") do
  prepare = step_named.call(deploy_job, "Prepare reviewed ECS task definition")
  assert.call(
    prepare.fetch("run").strip == "bash infra/scripts/prepare-ecs-task-definition.sh infra/terraform/staging task-definition.json",
    "workflow does not prepare the canonical task definition through the contract script",
  )
  assert.call(!deploy_job.fetch("env").key?("AWS_ECS_TASK_FAMILY"), "deploy still selects a task definition by family")
end

check.call("release preparation bridges only a Terraform-observed service revision to the canonical contract") do
  Dir.mktmpdir("prepare-ecs") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    aws_log = File.join(directory, "aws.log")
    output = File.join(directory, "task-definition.json")
    canonical_path = File.join(directory, "canonical.json")
    deployed_path = File.join(directory, "deployed.json")
    service_path = File.join(directory, "service.json")
    release_contract_path = File.join(directory, "release-contract.json")
    family = "dadamjang-staging-api"
    canonical_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/#{family}:50"
    old_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/#{family}:41"
    target_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/#{family}:51"
    image_reference = "registry.example/api@sha256:#{"c" * 64}"
    secret_names = %w[JWT_ACCESS_SECRET POSTGRES_PASSWORD]
    terraform_sources = Dir[File.join(root, "terraform/staging/*.tf")]
      .map { |path| File.basename(path) }
      .append(".terraform.lock.hcl")
      .sort
    source_hashes = terraform_sources.to_h do |name|
      [name, Digest::SHA256.file(File.join(root, "terraform/staging", name)).hexdigest]
    end
    build_task = lambda do |arn:, image:, release:, memory: "512"|
      {
        "taskDefinitionArn" => arn,
        "containerDefinitions" => [{
          "name" => "api",
          "image" => image,
          "essential" => true,
          "environment" => [
            { "name" => "NODE_ENV", "value" => "production" },
            { "name" => "POSTGRES_SSL", "value" => "true" },
            { "name" => "POSTGRES_SSL_CA_PATH", "value" => "/etc/ssl/certs/aws-rds-global-bundle.pem" },
            { "name" => "SENTRY_RELEASE", "value" => release },
          ],
          "secrets" => secret_names.map do |name|
            { "name" => name, "valueFrom" => "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:runtime:#{name}::" }
          end,
        }],
        "family" => family,
        "taskRoleArn" => "arn:aws:iam::123456789012:role/task",
        "executionRoleArn" => "arn:aws:iam::123456789012:role/execution",
        "networkMode" => "awsvpc",
        "revision" => arn.split(":").last.to_i,
        "volumes" => [],
        "status" => "ACTIVE",
        "requiresAttributes" => [],
        "placementConstraints" => [],
        "compatibilities" => ["EC2", "FARGATE"],
        "requiresCompatibilities" => ["FARGATE"],
        "cpu" => "256",
        "memory" => memory,
        "runtimePlatform" => { "cpuArchitecture" => "X86_64", "operatingSystemFamily" => "LINUX" },
        "registeredAt" => "2026-08-29T00:00:00Z",
        "registeredBy" => "terraform",
      }
    end
    canonical = build_task.call(arn: canonical_arn, image: "registry.example/api:bootstrap", release: "bootstrap")
    old = build_task.call(arn: old_arn, image: "registry.example/api@sha256:#{"b" * 64}", release: "old", memory: "256")
    release_contract = {
      "canonical_task_definition_arn" => canonical_arn,
      "observed_service_task_definition_arn" => old_arn,
      "task_family" => family,
      "image_repository" => "registry.example/api",
      "runtime_secret_names" => secret_names,
      "source_hashes" => source_hashes,
    }
    write_executable.call(File.join(fake_bin, "terraform"), <<~SH)
      #!/usr/bin/env bash
      [[ "$*" == *"output -json ecs_release_contract"* ]] || exit 2
      cat "$FAKE_RELEASE_CONTRACT"
    SH
    write_executable.call(File.join(fake_bin, "aws"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
      if [[ "$1 $2" == "ecs describe-services" ]]; then
        cat "$FAKE_SERVICE"
      elif [[ "$*" == *"$FAKE_CANONICAL_ARN"* ]]; then
        cat "$FAKE_CANONICAL_TASK"
      elif [[ "$*" == *"$FAKE_DEPLOYED_ARN"* ]]; then
        cat "$FAKE_DEPLOYED_TASK"
      else
        exit 2
      fi
    SH
    write_state = lambda do |deployed:, observed: release_contract.fetch("observed_service_task_definition_arn"), service_name: "staging-service"|
      File.write(canonical_path, JSON.generate({ "taskDefinition" => canonical }))
      File.write(deployed_path, JSON.generate({ "taskDefinition" => deployed }))
      File.write(
        service_path,
        JSON.generate({
          "services" => [{ "serviceName" => service_name, "status" => "ACTIVE", "taskDefinition" => deployed.fetch("taskDefinitionArn") }],
          "failures" => [],
        }),
      )
      File.write(
        release_contract_path,
        JSON.generate(release_contract.merge("observed_service_task_definition_arn" => observed)),
      )
    end
    write_state.call(deployed: old)
    env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_AWS_LOG" => aws_log,
      "FAKE_CANONICAL_ARN" => canonical_arn,
      "FAKE_DEPLOYED_ARN" => old_arn,
      "FAKE_CANONICAL_TASK" => canonical_path,
      "FAKE_DEPLOYED_TASK" => deployed_path,
      "FAKE_RELEASE_CONTRACT" => release_contract_path,
      "FAKE_SERVICE" => service_path,
      "AWS_ECS_CLUSTER" => "staging-cluster",
      "AWS_ECS_SERVICE" => "staging-service",
      "IMAGE_REFERENCE" => image_reference,
      "SENTRY_RELEASE" => "release-tag",
    }
    command = ["bash", File.join(root, "scripts/prepare-ecs-task-definition.sh"), "terraform/staging", output]

    _, stderr, status = Open3.capture3(env, *command, chdir: root)
    assert.call(status.success?, stderr.empty? ? "preparer did not consume the Terraform release transition" : stderr)
    expected_target = JSON.parse(JSON.generate(canonical))
    expected_api = expected_target.fetch("containerDefinitions").first
    expected_api["image"] = image_reference
    expected_api.fetch("environment").find { |item| item["name"] == "SENTRY_RELEASE" }["value"] = "release-tag"
    assert.call(JSON.parse(File.read(output)) == expected_target, "contract transition did not prepare the canonical target")
    calls = File.readlines(aws_log, chomp: true)
    assert.call(calls.first.include?("ecs describe-services"), "service task definition was not resolved first")
    assert.call(calls.none? { |call| call.include?("--task-definition #{family} ") }, "task family latest was queried")

    post_transition = JSON.parse(JSON.generate(expected_target))
    post_transition["taskDefinitionArn"] = target_arn
    post_transition["revision"] = 51
    post_transition["registeredBy"] = "github"
    write_state.call(deployed: post_transition)
    FileUtils.rm_f(output)
    _, stderr, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => target_arn), *command, chdir: root)
    assert.call(status.success?, "post-transition steady state failed: #{stderr}")

    write_state.call(deployed: canonical, observed: canonical_arn)
    FileUtils.rm_f(output)
    _, stderr, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
    assert.call(status.success?, "fresh bootstrap failed: #{stderr}")

    write_state.call(deployed: canonical, observed: canonical_arn, service_name: "other-service")
    FileUtils.rm_f(output)
    _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
    assert.call(!status.success?, "a response for the wrong ECS service was accepted")

    write_state.call(
      deployed: old,
      observed: "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/#{family}:39",
    )
    FileUtils.rm_f(output)
    _, _, status = Open3.capture3(env, *command, chdir: root)
    assert.call(!status.success?, "stale Terraform service state authorized a contract transition")
    assert.call(!File.exist?(output), "stale Terraform state produced a target")

    unrelated_drift = JSON.parse(JSON.generate(old))
    unrelated_drift["taskDefinitionArn"] = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/#{family}:52"
    unrelated_drift["revision"] = 52
    unrelated_drift["taskRoleArn"] = "arn:aws:iam::123456789012:role/unreviewed"
    write_state.call(deployed: unrelated_drift)
    FileUtils.rm_f(output)
    _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => unrelated_drift.fetch("taskDefinitionArn")), *command, chdir: root)
    assert.call(!status.success?, "unrelated live service drift was accepted as a contract transition")

    invalid_canonical_mutations = {
      "task family" => ->(task) { task["family"] = "other-family" },
      "task role" => ->(task) { task["taskRoleArn"] = "not-an-iam-role-arn" },
      "secret set" => ->(task) { task["containerDefinitions"][0]["secrets"] = [] },
      "PostgreSQL TLS" => lambda do |task|
        task["containerDefinitions"][0]["environment"].find { |item| item["name"] == "POSTGRES_SSL" }["value"] = "false"
      end,
      "runtime platform" => ->(task) { task["runtimePlatform"]["cpuArchitecture"] = "ARM64" },
      "API container" => ->(task) { task["containerDefinitions"][0]["name"] = "other" },
    }
    invalid_canonical_mutations.each do |name, mutate|
      invalid = JSON.parse(JSON.generate(canonical))
      mutate.call(invalid)
      canonical.replace(invalid)
      write_state.call(deployed: invalid, observed: canonical_arn)
      FileUtils.rm_f(output)
      _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
      assert.call(!status.success?, "invalid canonical #{name} was accepted")
      canonical.replace(build_task.call(arn: canonical_arn, image: "registry.example/api:bootstrap", release: "bootstrap"))
    end

    stale_hashes = release_contract.merge("source_hashes" => source_hashes.merge("application.tf" => "0" * 64))
    File.write(release_contract_path, JSON.generate(stale_hashes))
    write_state.call(deployed: canonical, observed: canonical_arn)
    File.write(release_contract_path, JSON.generate(stale_hashes))
    FileUtils.rm_f(output)
    _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
    assert.call(!status.success?, "Terraform state from different contract sources was accepted")

    missing_hash = release_contract.merge("source_hashes" => source_hashes.reject { |name| name == terraform_sources.first })
    File.write(release_contract_path, JSON.generate(missing_hash))
    _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
    assert.call(!status.success?, "Terraform state with a missing contract source was accepted")

    extra_hash = release_contract.merge("source_hashes" => source_hashes.merge("unexpected.tf" => "0" * 64))
    File.write(release_contract_path, JSON.generate(extra_hash))
    _, _, status = Open3.capture3(env.merge("FAKE_DEPLOYED_ARN" => canonical_arn), *command, chdir: root)
    assert.call(!status.success?, "Terraform state with an extra contract source was accepted")

    File.write(release_contract_path, JSON.generate(release_contract.merge("observed_service_task_definition_arn" => canonical_arn)))
    _, _, status = Open3.capture3(
      env.merge("FAKE_DEPLOYED_ARN" => canonical_arn, "IMAGE_REFERENCE" => "registry.example/api:mutable"),
      *command,
      chdir: root,
    )
    assert.call(!status.success?, "mutable image reference was accepted")

    _, _, status = Open3.capture3(
      env.merge(
        "FAKE_DEPLOYED_ARN" => canonical_arn,
        "IMAGE_REFERENCE" => "other.example/api@sha256:#{"c" * 64}",
      ),
      *command,
      chdir: root,
    )
    assert.call(!status.success?, "image from outside the Terraform repository was accepted")
  end
end

check.call("migration and service deploy use one registered task definition") do
  register_steps = deploy_job.fetch("steps").select do |step|
    uses_action.call(step, "aws-actions/amazon-ecs-deploy-task-definition")
  end
  assert.call(register_steps.length == 1, "task definition is not registered exactly once")
  register = register_steps.first
  assert.call(register.fetch("id") == "register-task-definition", "registered ARN is not captured")
  assert.call(register.fetch("with").keys == ["task-definition"], "register action also deploys a service")
  assert.call(register.dig("with", "task-definition") == "task-definition.json", "register action bypasses the prepared canonical target")
  deploy = step_named.call(deploy_job, "Migrate and deploy registered task definition")
  task_definition_output = "${{ steps.register-task-definition.outputs.task-definition-arn }}"
  assert.call(deploy.dig("env", "TASK_DEFINITION_ARN") == task_definition_output, "registered ARN is not passed to deploy")
  assert.call(
    deploy.fetch("run").strip == "bash infra/scripts/deploy-ecs-release.sh",
    "workflow does not invoke the deployment script through bash",
  )

  Dir.mktmpdir("deploy-ecs") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    aws_log = File.join(directory, "aws.log")
    run_task_input = File.join(directory, "run-task.json")
    write_executable.call(File.join(fake_bin, "aws"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
      case "$1 $2" in
        "ecs describe-services")
          if [[ "$*" == *"networkConfiguration.awsvpcConfiguration"* ]]; then
            printf '%s\n' '{"subnets":["subnet-0123456789abcdef0"],"securityGroups":["sg-0123456789abcdef0"],"assignPublicIp":"DISABLED"}'
          elif [[ "$*" == *'--query services[0].deployments[?status==`PRIMARY`].{taskDefinition:taskDefinition,rolloutState:rolloutState}'* ]]; then
            case "$FAKE_SERVICE_DEPLOYMENT" in
              success) printf '[{"taskDefinition":"%s","rolloutState":"COMPLETED"}]\n' "$TASK_DEFINITION_ARN" ;;
              rollback) printf '%s\n' '[{"taskDefinition":"arn:aws:ecs:ap-northeast-2:123456789012:task-definition/dadamjang-staging-api:41","rolloutState":"COMPLETED"}]' ;;
              incomplete) printf '[{"taskDefinition":"%s","rolloutState":"IN_PROGRESS"}]\n' "$TASK_DEFINITION_ARN" ;;
              missing) printf '%s\n' '[]' ;;
              multiple) printf '[{"taskDefinition":"%s","rolloutState":"COMPLETED"},{"taskDefinition":"arn:aws:ecs:ap-northeast-2:123456789012:task-definition/dadamjang-staging-api:41","rolloutState":"COMPLETED"}]\n' "$TASK_DEFINITION_ARN" ;;
              error) printf '%s\n' 'AccessDeniedException: denied' >&2; exit 255 ;;
              *) exit 3 ;;
            esac
          else
            exit 3
          fi
          ;;
        "ecs run-task")
          shift 2
          while (($#)); do
            if [[ "$1" == "--cli-input-json" ]]; then
              printf '%s' "$2" > "$FAKE_RUN_TASK_INPUT"
              break
            fi
            shift
          done
          printf '%s\n' 'arn:aws:ecs:ap-northeast-2:123456789012:task/staging/abc123'
          ;;
        "ecs describe-tasks") printf '%s\n' '0' ;;
        "ecs wait"|"ecs update-service") ;;
        *) exit 2 ;;
      esac
    SH
    task_definition_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/dadamjang-staging-api:42"
    env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_AWS_LOG" => aws_log,
      "FAKE_RUN_TASK_INPUT" => run_task_input,
      "AWS_ECS_CLUSTER" => "staging-cluster",
      "AWS_ECS_SERVICE" => "staging-service",
      "TASK_DEFINITION_ARN" => task_definition_arn,
    }
    command = ["bash", File.join(root, "scripts/deploy-ecs-release.sh")]
    _, stderr, status = Open3.capture3(env.merge("FAKE_SERVICE_DEPLOYMENT" => "success"), *command, chdir: root)
    assert.call(status.success?, stderr)
    payload = JSON.parse(File.read(run_task_input))
    assert.call(payload.fetch("taskDefinition") == task_definition_arn, "migration uses another task definition")
    override = payload.dig("overrides", "containerOverrides", 0)
    assert.call(override == { "name" => "api", "command" => ["node", "dist/scripts/migrate.js"] }, "migration override is not command-only")
    assert.call(payload.dig("networkConfiguration", "awsvpcConfiguration", "assignPublicIp") == "DISABLED", "migration task is public")

    aws_env = { "AWS_DEFAULT_REGION" => "ap-northeast-2", "AWS_EC2_METADATA_DISABLED" => "true", "AWS_PAGER" => "" }
    _, validation_error, validation_status = Open3.capture3(
      aws_env, "aws", "ecs", "run-task", "--cli-input-json", JSON.generate(payload), "--generate-cli-skeleton", "output",
    )
    assert.call(validation_status.success?, validation_error)

    calls = File.readlines(aws_log, chomp: true)
    failure_results = %w[rollback incomplete missing multiple error].to_h do |scenario|
      FileUtils.rm_f(aws_log)
      _, _, scenario_status = Open3.capture3(env.merge("FAKE_SERVICE_DEPLOYMENT" => scenario), *command, chdir: root)
      [scenario, scenario_status.success?]
    end
    run_index = calls.index { |call| call.start_with?("ecs run-task ") } || raise("run-task was not called")
    update_index = calls.index { |call| call.start_with?("ecs update-service ") } || raise("update-service was not called")
    wait_index = calls.index { |call| call == "ecs wait services-stable --cluster staging-cluster --services staging-service" } || raise("service stability is not awaited")
    assert.call(run_index < update_index, "service updates before migration")
    assert.call(calls[update_index].include?("--task-definition #{task_definition_arn}"), "service uses another task definition")
    assert.call(wait_index < calls.length - 1, "service deployment is not inspected after the waiter")

    accepted_failures = failure_results.select { |_, succeeded| succeeded }.keys
    assert.call(accepted_failures.empty?, "deployment verification accepted #{accepted_failures.join(", ")}")
  end
end

exit(failures.empty? ? 0 : 1)
