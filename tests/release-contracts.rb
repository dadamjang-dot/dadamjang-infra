#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "set"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/api-deploy.yml"))
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
  File.read(File.join(root, path)).gsub(%r{/\*.*?\*/}m, "").gsub(%r{//.*$}, "").gsub(/#.*$/, "")
end

runtime_keys = lambda do |path|
  body = active_hcl.call(path)[/runtime_secret_keys\s*=\s*toset\(\[(.*?)\]\)/m, 1] || raise("missing runtime_secret_keys")
  body.scan(/"([A-Z0-9_]+)"/).flatten.to_set
end

write_executable = lambda do |path, body|
  File.write(path, body)
  FileUtils.chmod(0o755, path)
end

check.call("Docker build and runtime use backend build outputs") do
  instructions = File.readlines(File.join(root, "docker/backend.Dockerfile"), chomp: true)
    .map(&:strip)
    .reject { |line| line.empty? || line.start_with?("#") }
  assert.call(instructions.none? { |line| line.include?("tsc scripts/migrate.ts") }, "standalone tsc remains")
  assert.call(
    instructions.include?('CMD ["sh", "-c", "node dist/scripts/migrate.js && node dist/src/main.js"]'),
    "runtime command does not use emitted paths",
  )
end

check.call("e2e task starts the emitted backend entrypoint") do
  application = active_hcl.call("terraform/e2e/application.tf")
  assert.call(application.include?('command = ["node", "dist/src/main.js"]'), "wrong e2e entrypoint")
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
  assert.call(deploy_job.fetch("concurrency") == { "group" => "staging-api-deploy", "cancel-in-progress" => true }, "deploy is not serialized")
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
  assert.call(publish.dig("env", "IMAGE_TAG") == "${{ needs.test.outputs.image_tag }}", "publish tag is not test output")
  assert.call(
    publish.fetch("run").start_with?("bash infra/scripts/publish-backend-image.sh "),
    "workflow does not invoke the image publisher through bash",
  )
  render_steps = deploy_job.fetch("steps").select { |step| step["uses"] == "aws-actions/amazon-ecs-render-task-definition@v1" }
  assert.call(render_steps.length == 1, "deploy must render exactly one image reference")
  render = render_steps.first
  expected_image = "${{ steps.ecr-login.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ needs.test.outputs.image_tag }}"
  assert.call(render.dig("with", "image") == expected_image, "rendered image is not the tested image")
end

check.call("image publication safely reuses immutable ECR tags") do
  Dir.mktmpdir("publish-image") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    docker_log = File.join(directory, "docker.log")
    write_executable.call(File.join(fake_bin, "aws"), <<~SH)
      #!/usr/bin/env bash
      case "$FAKE_ECR_RESULT" in
        existing) exit 0 ;;
        missing) printf '%s\n' 'ImageNotFoundException: missing' >&2; exit 254 ;;
        *) printf '%s\n' 'AccessDeniedException: denied' >&2; exit 255 ;;
      esac
    SH
    write_executable.call(File.join(fake_bin, "docker"), <<~SH)
      #!/usr/bin/env bash
      printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
    SH
    base_env = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "FAKE_DOCKER_LOG" => docker_log,
    }
    command = [
      "bash", File.join(root, "scripts/publish-backend-image.sh"), "registry.example", "api", "release-tag",
      "infra/docker/backend.Dockerfile", "backend",
    ]

    _, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "existing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(!File.exist?(docker_log), "existing image was rebuilt")

    _, stderr, status = Open3.capture3(base_env.merge("FAKE_ECR_RESULT" => "missing"), *command, chdir: root)
    assert.call(status.success?, stderr)
    assert.call(
      File.readlines(docker_log, chomp: true) == [
        "build --file infra/docker/backend.Dockerfile --tag registry.example/api:release-tag backend",
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
          printf '%s\n' '{"subnets":["subnet-0123456789abcdef0"],"securityGroups":["sg-0123456789abcdef0"],"assignPublicIp":"DISABLED"}'
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
    _, stderr, status = Open3.capture3(env, "bash", File.join(root, "scripts/deploy-ecs-release.sh"), chdir: root)
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
    run_index = calls.index { |call| call.start_with?("ecs run-task ") } || raise("run-task was not called")
    update_index = calls.index { |call| call.start_with?("ecs update-service ") } || raise("update-service was not called")
    assert.call(run_index < update_index, "service updates before migration")
    assert.call(calls[update_index].include?("--task-definition #{task_definition_arn}"), "service uses another task definition")
    assert.call(calls.last == "ecs wait services-stable --cluster staging-cluster --services staging-service", "service stability is not awaited")
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
  ])
  %w[terraform/staging/locals.tf terraform/e2e/locals.tf].each do |path|
    missing = required - runtime_keys.call(path)
    assert.call(missing.empty?, "#{path} misses #{missing.to_a.sort.join(", ")}")
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
end

exit(failures.empty? ? 0 : 1)
