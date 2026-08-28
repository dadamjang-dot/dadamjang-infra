#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "set"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/api-deploy.yml"))
infra_ci = YAML.load_file(File.join(root, ".github/workflows/infra-ci.yml"))
infra_ci_triggers = infra_ci["on"] || infra_ci.fetch(true)
jobs = workflow.fetch("jobs")
test_job = jobs.fetch("test")
deploy_job = jobs.fetch("deploy")
failures = []

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

active_hcl = lambda do |path|
  File.read(File.join(root, path))
    .gsub(%r{/\*.*?\*/}m, "")
    .lines
    .reject { |line| line.match?(%r{^\s*(?:#|//)}) }
    .join
end

hcl_block_from = lambda do |source, pattern|
  match = source.match(pattern) || raise("missing HCL block #{pattern.inspect}")
  opening = source.index("{", match.end(0)) || raise("missing opening brace for #{pattern.inspect}")
  depth = 0
  escaped = false
  in_string = false
  result = nil

  source[opening..].each_char.with_index do |character, index|
    if in_string
      if escaped
        escaped = false
      elsif character == "\\"
        escaped = true
      elsif character == '"'
        in_string = false
      end
      next
    end

    case character
    when '"'
      in_string = true
    when "{"
      depth += 1
    when "}"
      depth -= 1
      if depth.zero?
        result = source[opening..(opening + index)]
        break
      end
    end
  end

  result || raise("missing closing brace for #{pattern.inspect}")
end

hcl_block = lambda do |path, pattern|
  hcl_block_from.call(active_hcl.call(path), pattern)
end

hcl_arguments = lambda do |block|
  block.scan(/^\s*([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$/).to_h
end

task_environment = lambda do |path|
  task = hcl_block.call(path, /resource\s+"aws_ecs_task_definition"\s+"api"/)
  environment = task[/environment\s*=\s*\[(.*?)\]\s*essential/m, 1] || raise("missing task environment")
  environment.scan(/\{\s*name\s*=\s*"([A-Z0-9_]+)"\s*,\s*value\s*=\s*([^}\n]+)\}/).to_h do |name, value|
    [name, value.strip]
  end
end

runtime_keys = lambda do |path|
  body = active_hcl.call(path)[/runtime_secret_keys\s*=\s*toset\(\[(.*?)\]\)/m, 1] || raise("missing runtime_secret_keys")
  body.scan(/"([A-Z0-9_]+)"/).flatten.to_set
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
    instructions.include?('CMD ["sh", "-c", "node dist/scripts/migrate.js && node dist/src/main.js"]'),
    "runtime command does not use emitted paths",
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

check.call("e2e task starts the emitted backend entrypoint") do
  application = active_hcl.call("terraform/e2e/application.tf")
  assert.call(application.include?('command = ["node", "dist/src/main.js"]'), "wrong e2e entrypoint")
end

check.call("infra CI watches release behavior and documentation") do
  required_paths = Set.new(["README.md", "scripts/**"])
  %w[pull_request push].each do |event|
    configured_paths = infra_ci_triggers.fetch(event).fetch("paths").to_set
    missing_paths = required_paths - configured_paths
    assert.call(missing_paths.empty?, "#{event} omits #{missing_paths.to_a.join(", ")}")
  end
end

check.call("test job owns the PostgreSQL integration service") do
  postgres = test_job.fetch("services").fetch("postgres")
  assert.call(postgres.fetch("image") == "postgres:16-alpine", "wrong PostgreSQL image")
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
    step["uses"] == "actions/checkout@v4" && step.dig("with", "repository") == "dadamjang-dot/dadamjang-be"
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
  render_steps = deploy_job.fetch("steps").select { |step| step["uses"] == "aws-actions/amazon-ecs-render-task-definition@v1" }
  assert.call(render_steps.length == 1, "deploy must render exactly one image reference")
  render = render_steps.first
  expected_image = "${{ steps.image.outputs.reference }}"
  assert.call(render.dig("with", "image") == expected_image, "rendered image is not the tested image")
  release_environment = render.dig("with", "environment-variables").to_s.lines(chomp: true).to_h do |line|
    line.split("=", 2)
  end
  assert.call(
    release_environment["SENTRY_RELEASE"] == "${{ needs.test.outputs.image_tag }}",
    "deployed Sentry release is not the tested immutable image tag",
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
      printf '%s\n' 'docker progress'
    SH
    base_env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_AWS_LOG" => File.join(directory, "aws.log"),
      "FAKE_DOCKER_LOG" => docker_log,
    }
    command = [
      "bash", File.join(root, "scripts/publish-backend-image.sh"), "registry.example", "api", "release-tag",
      "infra/docker/backend.Dockerfile", "backend",
    ]

    stdout, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "existing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(stdout.strip == "registry.example/api@sha256:#{"a" * 64}", "existing tag did not resolve to a digest reference")
    assert.call(!File.exist?(docker_log), "existing image was rebuilt")

    stdout, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "missing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(stdout.strip == "registry.example/api@sha256:#{"a" * 64}", "pushed tag did not resolve to a digest reference")
    assert.call(
      File.readlines(docker_log, chomp: true) == [
        "build --platform linux/amd64 --file infra/docker/backend.Dockerfile --tag registry.example/api:release-tag backend",
        "push registry.example/api:release-tag",
      ],
      "missing image did not build and push once",
    )

    File.delete(docker_log)
    _, _, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "denied"), *command, chdir: root)
    assert.call(!status.success?, "unexpected ECR error was treated as a missing image")
    assert.call(!File.exist?(docker_log), "unexpected ECR error triggered Docker")
  end
end

check.call("release preparation uses the deployed service and Terraform task contract") do
  prepare = step_named.call(deploy_job, "Read deployed ECS task definition")
  assert.call(
    prepare.fetch("run").strip == "bash infra/scripts/prepare-ecs-task-definition.sh infra/terraform/staging task-definition.json",
    "workflow does not prepare the deployed task definition through the contract script",
  )
  assert.call(!deploy_job.fetch("env").key?("AWS_ECS_TASK_FAMILY"), "deploy still selects a task definition by family")
  output = hcl_block.call("terraform/staging/outputs.tf", /output\s+"ecs_task_definition_arn"/)
  assert.call(hcl_arguments.call(output)["value"] == "aws_ecs_task_definition.api.arn", "Terraform state does not expose the reviewed task definition ARN")

  Dir.mktmpdir("prepare-ecs") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    aws_log = File.join(directory, "aws.log")
    output = File.join(directory, "task-definition.json")
    canonical_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/dadamjang-staging-api:40"
    deployed_arn = "arn:aws:ecs:ap-northeast-2:123456789012:task-definition/dadamjang-staging-api:41"
    canonical = {
      "taskDefinitionArn" => canonical_arn,
      "containerDefinitions" => [{
        "name" => "api",
        "image" => "registry.example/api:bootstrap",
        "essential" => true,
        "environment" => [
          { "name" => "NODE_ENV", "value" => "production" },
          { "name" => "POSTGRES_SSL", "value" => "true" },
          { "name" => "POSTGRES_SSL_CA_PATH", "value" => "/etc/ssl/certs/aws-rds-global-bundle.pem" },
          { "name" => "SENTRY_RELEASE", "value" => "bootstrap" },
        ],
        "secrets" => [{ "name" => "POSTGRES_PASSWORD", "valueFrom" => "arn:aws:secretsmanager:database:password::" }],
      }],
      "family" => "dadamjang-staging-api",
      "taskRoleArn" => "arn:aws:iam::123456789012:role/task",
      "executionRoleArn" => "arn:aws:iam::123456789012:role/execution",
      "networkMode" => "awsvpc",
      "revision" => 40,
      "volumes" => [],
      "status" => "ACTIVE",
      "requiresAttributes" => [],
      "placementConstraints" => [],
      "compatibilities" => ["EC2", "FARGATE"],
      "requiresCompatibilities" => ["FARGATE"],
      "cpu" => "256",
      "memory" => "512",
      "runtimePlatform" => { "cpuArchitecture" => "X86_64", "operatingSystemFamily" => "LINUX" },
      "registeredAt" => "2026-08-28T00:00:00Z",
      "registeredBy" => "terraform",
    }
    deployed = JSON.parse(JSON.generate(canonical))
    deployed["taskDefinitionArn"] = deployed_arn
    deployed["revision"] = 41
    deployed["registeredAt"] = "2026-08-29T00:00:00Z"
    deployed["registeredBy"] = "github"
    deployed["containerDefinitions"][0]["image"] = "registry.example/api@sha256:#{"b" * 64}"
    deployed["containerDefinitions"][0]["environment"].find { |item| item["name"] == "SENTRY_RELEASE" }["value"] = "release-tag"
    canonical_path = File.join(directory, "canonical.json")
    deployed_path = File.join(directory, "deployed.json")
    File.write(canonical_path, JSON.generate({ "taskDefinition" => canonical }))
    File.write(deployed_path, JSON.generate({ "taskDefinition" => deployed }))
    write_executable.call(File.join(fake_bin, "terraform"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$FAKE_CANONICAL_ARN"
    SH
    write_executable.call(File.join(fake_bin, "aws"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
      if [[ "$1 $2" == "ecs describe-services" ]]; then
        printf '%s\n' "$FAKE_DEPLOYED_ARN"
      elif [[ "$*" == *"$FAKE_CANONICAL_ARN"* ]]; then
        cat "$FAKE_CANONICAL_TASK"
      elif [[ "$*" == *"$FAKE_DEPLOYED_ARN"* ]]; then
        cat "$FAKE_DEPLOYED_TASK"
      else
        exit 2
      fi
    SH
    env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_AWS_LOG" => aws_log,
      "FAKE_CANONICAL_ARN" => canonical_arn,
      "FAKE_DEPLOYED_ARN" => deployed_arn,
      "FAKE_CANONICAL_TASK" => canonical_path,
      "FAKE_DEPLOYED_TASK" => deployed_path,
      "AWS_ECS_CLUSTER" => "staging-cluster",
      "AWS_ECS_SERVICE" => "staging-service",
    }
    command = ["bash", File.join(root, "scripts/prepare-ecs-task-definition.sh"), "terraform/staging", output]
    _, stderr, status = Open3.capture3(env, *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(JSON.parse(File.read(output)) == deployed, "prepared task definition is not the deployed service revision")
    calls = File.readlines(aws_log, chomp: true)
    assert.call(calls.first.include?("ecs describe-services"), "service task definition was not resolved first")
    assert.call(calls.none? { |call| call.include?("--task-definition dadamjang-staging-api ") }, "task family latest was queried")

    drifted = JSON.parse(JSON.generate(deployed))
    drifted["containerDefinitions"][0]["secrets"] = []
    File.write(deployed_path, JSON.generate({ "taskDefinition" => drifted }))
    FileUtils.rm_f(output)
    _, _, drift_status = Open3.capture3(env, *command, chdir: root)
    assert.call(!drift_status.success?, "secret contract drift was accepted")
    assert.call(!File.exist?(output), "invalid task definition was rendered")

    invalid_tls = JSON.parse(JSON.generate(canonical))
    invalid_tls["containerDefinitions"][0]["environment"].find { |item| item["name"] == "POSTGRES_SSL" }["value"] = "false"
    File.write(canonical_path, JSON.generate({ "taskDefinition" => invalid_tls }))
    File.write(deployed_path, JSON.generate({ "taskDefinition" => invalid_tls.merge("taskDefinitionArn" => deployed_arn, "revision" => 41) }))
    _, _, tls_status = Open3.capture3(env, *command, chdir: root)
    assert.call(!tls_status.success?, "matching task definitions with disabled PostgreSQL TLS were accepted")
  end
end

check.call("migration and service deploy use one registered task definition") do
  register_steps = deploy_job.fetch("steps").select do |step|
    step["uses"] == "aws-actions/amazon-ecs-deploy-task-definition@v2"
  end
  assert.call(register_steps.length == 1, "task definition is not registered exactly once")
  register = register_steps.first
  assert.call(register.fetch("id") == "register-task-definition", "registered ARN is not captured")
  assert.call(register.fetch("with").keys == ["task-definition"], "register action also deploys a service")
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

check.call("staging OIDC trust remains environment-scoped") do
  iam = active_hcl.call("terraform/staging/iam.tf")
  assert.call(iam.include?('values   = ["repo:${var.github_repository}:environment:${var.environment}"]'), "wrong OIDC subject")
  assert.call(!iam.include?(":ref:refs/heads/"), "branch OIDC subject remains")
  assert.call(iam.include?('"ecr:DescribeImages"'), "image existence check lacks IAM permission")
end

check.call("staging and e2e inject the shared backend runtime contract") do
  required = Set.new(%w[
    API_PUBLIC_BASE_URL
    DADAMJANG_BO_URL
    IDENTITY_CI_PEPPER
    IDENTITY_INICIS_API_KEY
    IDENTITY_INICIS_CALLBACK_BASE_URL
    IDENTITY_INICIS_MID
    IDENTITY_INICIS_SEED_IV
    SENTRY_DSN
  ])
  paths = %w[terraform/staging/locals.tf terraform/e2e/locals.tf]
  paths.each do |path|
    missing = required - runtime_keys.call(path)
    assert.call(missing.empty?, "#{path} misses #{missing.to_a.sort.join(", ")}")
  end
  assert.call(runtime_keys.call(paths[0]) == runtime_keys.call(paths[1]), "staging and e2e secret key contracts diverge")
end

check.call("staging and e2e tasks require verified PostgreSQL TLS and environment-specific Sentry metadata") do
  expected = {
    "terraform/staging/application.tf" => {
      "POSTGRES_SSL" => '"true"',
      "POSTGRES_SSL_CA_PATH" => '"/etc/ssl/certs/aws-rds-global-bundle.pem"',
      "SENTRY_ENVIRONMENT" => '"staging"',
      "SENTRY_RELEASE" => "var.api_image_tag",
    },
    "terraform/e2e/application.tf" => {
      "POSTGRES_SSL" => '"true"',
      "POSTGRES_SSL_CA_PATH" => '"/etc/ssl/certs/aws-rds-global-bundle.pem"',
      "SENTRY_ENVIRONMENT" => '"e2e"',
      "SENTRY_RELEASE" => "var.api_image_tag",
    },
  }

  expected.each do |path, required_environment|
    actual_environment = task_environment.call(path)
    required_environment.each do |name, value|
      assert.call(actual_environment[name] == value, "#{path} has wrong #{name}")
    end
  end
end

check.call("staging and e2e tasks pin the published Fargate platform") do
  %w[terraform/staging/application.tf terraform/e2e/application.tf].each do |path|
    task = hcl_block.call(path, /resource\s+"aws_ecs_task_definition"\s+"api"/)
    platform = hcl_arguments.call(hcl_block_from.call(task, /runtime_platform/))
    assert.call(platform["cpu_architecture"] == '"X86_64"', "#{path} does not require amd64")
    assert.call(platform["operating_system_family"] == '"LINUX"', "#{path} does not require Linux")
  end
end

check.call("staging and e2e ALBs use the exact readiness contract") do
  %w[terraform/staging/application.tf terraform/e2e/application.tf].each do |path|
    target_group = hcl_block.call(path, /resource\s+"aws_lb_target_group"\s+"api"/)
    health_check = hcl_block_from.call(target_group, /health_check/)
    arguments = hcl_arguments.call(health_check)
    assert.call(arguments["path"] == '"/health/ready"', "#{path} does not use the readiness endpoint")
    assert.call(arguments["matcher"] == '"200"', "#{path} accepts non-200 health responses")
  end
end

check.call("staging ECS service waits for the HTTPS listener") do
  graph, error, status = Open3.capture3("terraform", "-chdir=terraform/staging", "graph", "-type=plan", chdir: root)
  assert.call(status.success?, error)
  edge = '"[root] aws_ecs_service.api (expand)" -> "[root] aws_lb_listener.https (expand)"'
  assert.call(graph.include?(edge), "staging ECS service does not depend on the HTTPS listener")
end

check.call("staging RDS deletion protection and final snapshot policy are independently safe") do
  variables = {
    "enable_deletion_protection" => "true",
    "skip_final_snapshot" => "false",
    "final_snapshot_identifier" => "null",
  }
  variables.each do |name, default|
    block = hcl_block.call("terraform/staging/variables.tf", /variable\s+"#{name}"/)
    assert.call(hcl_arguments.call(block)["default"] == default, "#{name} has unsafe default")
  end

  database = hcl_block.call("terraform/staging/application.tf", /resource\s+"aws_db_instance"\s+"main"/)
  arguments = hcl_arguments.call(database)
  assert.call(arguments["deletion_protection"] == "var.enable_deletion_protection", "RDS deletion protection is not independently configured")
  assert.call(arguments["skip_final_snapshot"] == "var.skip_final_snapshot", "RDS final snapshot policy remains coupled to deletion protection")
  final_identifier = arguments.fetch("final_snapshot_identifier")
  expected_final_identifier = 'var.skip_final_snapshot ? null : coalesce(var.final_snapshot_identifier, "${local.name_prefix}-postgres-final")'
  assert.call(final_identifier == expected_final_identifier, "final snapshot identifier does not use the exact deterministic fallback")
  assert.call(!final_identifier.match?(/\b(?:timestamp|plantimestamp|uuid|uuidv5)\s*\(/), "final snapshot identifier uses nondeterministic generation")

  e2e_database = hcl_block.call("terraform/e2e/application.tf", /resource\s+"aws_db_instance"\s+"main"/)
  e2e_arguments = hcl_arguments.call(e2e_database)
  assert.call(e2e_arguments["deletion_protection"] == "false", "e2e database is no longer disposable")
  assert.call(e2e_arguments["skip_final_snapshot"] == "true", "e2e database now requires final snapshots")
end

check.call("staging alarms notify optional actions and cover ALB and target health failures") do
  actions_variable = hcl_block.call("terraform/staging/variables.tf", /variable\s+"alarm_action_arns"/)
  assert.call(hcl_arguments.call(actions_variable)["default"] == "[]", "alarm actions are not optional by default")

  expected_metrics = {
    "api_cpu" => "CPUUtilization",
    "api_memory" => "MemoryUtilization",
    "api_alb_5xx" => "HTTPCode_ELB_5XX_Count",
    "api_unhealthy_hosts" => "UnHealthyHostCount",
    "api_zero_healthy_hosts" => "HealthyHostCount",
  }
  expected_metrics.each do |name, metric|
    alarm = hcl_block.call("terraform/staging/application.tf", /resource\s+"aws_cloudwatch_metric_alarm"\s+"#{name}"/)
    arguments = hcl_arguments.call(alarm)
    assert.call(arguments["metric_name"] == "\"#{metric}\"", "#{name} uses the wrong metric")
    assert.call(arguments["alarm_actions"] == "var.alarm_action_arns", "#{name} does not use optional alarm actions")
  end

  alb_alarm = hcl_block.call("terraform/staging/application.tf", /resource\s+"aws_cloudwatch_metric_alarm"\s+"api_alb_5xx"/)
  alb_dimensions = hcl_arguments.call(hcl_block_from.call(alb_alarm, /dimensions\s*=/))
  assert.call(alb_dimensions == { "LoadBalancer" => "aws_lb.api.arn_suffix" }, "ALB 5xx alarm dimensions are wrong")

  %w[api_unhealthy_hosts api_zero_healthy_hosts].each do |name|
    alarm = hcl_block.call("terraform/staging/application.tf", /resource\s+"aws_cloudwatch_metric_alarm"\s+"#{name}"/)
    dimensions = hcl_arguments.call(hcl_block_from.call(alarm, /dimensions\s*=/))
    assert.call(dimensions["LoadBalancer"] == "aws_lb.api.arn_suffix", "#{name} misses the ALB dimension")
    assert.call(dimensions["TargetGroup"] == "aws_lb_target_group.api.arn_suffix", "#{name} misses the target group dimension")
  end
end

check.call("README documents the staging rollout contract") do
  readme = File.read(File.join(root, "README.md"))
  secret_json = readme[/```json\n(.*?)\n```/m, 1] || raise("missing runtime secret JSON example")
  documented_keys = JSON.parse(secret_json).keys.to_set
  assert.call(documented_keys == runtime_keys.call("terraform/staging/locals.tf"), "README secret JSON does not mirror staging")
  assert.call(readme.include?("배포 branch를 `main`으로만 제한"), "README lacks the main-only environment rule")
  assert.call(readme.include?("Prevent self-review"), "README lacks the no-self-approval setting")
  assert.call(readme.include?("새 task definition을 등록하기 전에 위 JSON의 모든 key"), "README lacks the secret rollout requirement")
  assert.call(
    readme.include?("backend-<backend-sha>-dockerfile-<dockerfile-blob-sha>"),
    "README lacks immutable image provenance",
  )
  transform_base = JSON.parse(secret_json).fetch("CLOUDFLARE_IMAGES_TRANSFORM_BASE_URL")
  assert.call(transform_base.start_with?("https://"), "Cloudflare transform base is not HTTPS")
  assert.call(transform_base.end_with?("/cdn-cgi/image"), "Cloudflare transform base is not a zone image transform path")
  assert.call(readme.include?("/etc/ssl/certs/aws-rds-global-bundle.pem"), "README lacks the RDS TLS CA path")
  assert.call(readme.include?("https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"), "README lacks the official AWS RDS bundle URL")
  assert.call(readme.include?("e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3"), "README lacks the current AWS RDS bundle checksum")
  assert.call(readme.include?("fail closed"), "README lacks the fail-closed AWS RDS bundle rotation behavior")
  assert.call(readme.include?("sha256sum"), "README lacks independent AWS RDS bundle checksum verification")
  assert.call(readme.include?("인증서 출처"), "README lacks independent AWS RDS certificate source verification")
  assert.call(readme.include?("검토"), "README lacks review before updating the AWS RDS checksum pin")
  assert.call(readme.include?("alarm_action_arns") && readme.include?("SNS topic ARN"), "README lacks the alarm SNS prerequisite")
  assert.call(readme.include?("skip_final_snapshot"), "README lacks the final snapshot switch")
  assert.call(readme.include?("final_snapshot_identifier"), "README lacks the final snapshot identifier override")
  assert.call(readme.include?("aws rds delete-db-snapshot"), "README lacks snapshot collision cleanup guidance")
  assert.call(readme.include?("/health/ready"), "README lacks the readiness rollout prerequisite")
end

exit(failures.empty? ? 0 : 1)
