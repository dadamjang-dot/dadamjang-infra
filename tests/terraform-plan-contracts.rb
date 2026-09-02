#!/usr/bin/env ruby

require "json"
require "open3"
require "shellwords"
require "yaml"

root = File.expand_path("..", __dir__)
terraform_workflow = YAML.load_file(File.join(root, ".github/workflows/terraform-apply.yml"))
deploy_workflow = YAML.load_file(File.join(root, ".github/workflows/api-deploy.yml"))
infra_ci = YAML.load_file(File.join(root, ".github/workflows/infra-ci.yml"))
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

terraform_apply_command = lambda do |command|
  command.gsub(/\\\r?\n/, " ").lines.any? do |line|
    tokens = Shellwords.shellsplit(line)
    tokens.each_index.any? do |index|
      next false unless tokens[index] == "terraform"

      arguments = tokens[(index + 1)..-1] || []
      while arguments.first&.start_with?("-")
        option = arguments.shift
        arguments.shift if option == "-chdir"
      end
      arguments.first == "apply"
    end
  rescue ArgumentError
    false
  end
end

check.call("Terraform apply detection handles CLI global options") do
  assert.call(
    terraform_apply_command.call("terraform -chdir=terraform/staging apply -input=false staging.tfplan"),
    "Terraform apply detection misses -chdir before the subcommand",
  )
  assert.call(
    !terraform_apply_command.call("terraform -chdir=terraform/staging plan -input=false -out=staging.tfplan"),
    "Terraform apply detection rejects a plan command",
  )
end

check.call("Terraform workflow is plan-only with complete protected inputs") do
  triggers = terraform_workflow["on"] || terraform_workflow.fetch(true)
  dispatch = triggers.fetch("workflow_dispatch") || {}
  terraform_job = terraform_workflow.fetch("jobs").fetch("terraform")
  terraform_env = terraform_job.fetch("env")
  assert.call((dispatch["inputs"] || {}).empty?, "Terraform workflow still exposes an apply mode")
  assert.call(terraform_env.fetch("TF_VAR_acm_certificate_arn") == "${{ vars.ACM_CERTIFICATE_ARN }}", "ACM certificate ARN is not supplied to Terraform")
  assert.call(terraform_env.fetch("TF_VAR_api_hostname") == "${{ vars.API_HOSTNAME }}", "API hostname is not supplied to Terraform")
  assert.call(terraform_env.fetch("TF_VAR_cloudflare_account_id") == "${{ vars.CLOUDFLARE_ACCOUNT_ID }}", "Cloudflare account ID is not supplied to Terraform")
  assert.call(terraform_env.fetch("TF_VAR_cloudflare_r2_final_bucket_name") == "${{ vars.CLOUDFLARE_R2_FINAL_BUCKET_NAME }}", "final R2 bucket name is not supplied to Terraform")

  validation = step_named.call(terraform_job, "Validate Terraform inputs")
  initialization = step_named.call(terraform_job, "Initialize Terraform state backend")
  plan = step_named.call(terraform_job, "Terraform plan")
  assert.call(terraform_job.fetch("steps").index(validation) < terraform_job.fetch("steps").index(initialization), "Terraform inputs are not validated before initialization")
  assert.call(
    initialization.fetch("run").split.grep(/\A-backend-config=/) == ["-backend-config=backend.hcl"],
    "Terraform plan passes unsupported inline backend configuration",
  )
  deploy_job = deploy_workflow.fetch("jobs").fetch("deploy")
  deploy_initialization = step_named.call(deploy_job, "Initialize Terraform state backend")
  assert.call(
    deploy_initialization.fetch("run").split.grep(/\A-backend-config=/) == ["-backend-config=backend.hcl"],
    "release state reads pass unsupported inline backend configuration",
  )
  _, _, empty_status = Open3.capture3(
    {
      "CLOUDFLARE_API_TOKEN" => nil,
      "TF_VAR_acm_certificate_arn" => nil,
      "TF_VAR_api_hostname" => nil,
      "TF_VAR_cloudflare_account_id" => nil,
      "TF_VAR_cloudflare_r2_final_bucket_name" => nil,
    },
    "bash", "-eu", "-c", validation.fetch("run"),
    chdir: root,
  )
  _, valid_error, valid_status = Open3.capture3(
    {
      "CLOUDFLARE_API_TOKEN" => "test-token",
      "TF_VAR_acm_certificate_arn" => "arn:aws:acm:ap-northeast-2:123456789012:certificate/example",
      "TF_VAR_api_hostname" => "api.staging.example.test",
      "TF_VAR_cloudflare_account_id" => "00000000000000000000000000000000",
      "TF_VAR_cloudflare_r2_final_bucket_name" => "dadamjang-staging-final",
    },
    "bash", "-eu", "-c", validation.fetch("run"),
    chdir: root,
  )
  assert.call(!empty_status.success?, "Terraform input validation accepts blank protected variables")
  assert.call(valid_status.success?, valid_error)

  workflow_commands = terraform_job.fetch("steps").map { |step| step["run"] }.compact
  assert.call(!workflow_commands.any? { |command| terraform_apply_command.call(command) }, "Terraform workflow can still apply an unreviewed plan")
  artifact_uploads = terraform_job.fetch("steps").select do |step|
    step["uses"].to_s.start_with?("actions/upload-artifact@")
  end
  assert.call(artifact_uploads.empty?, "Terraform plan job uploads an artifact")
  tfplan_handoffs = (terraform_job.fetch("steps") - [plan]).select do |step|
    JSON.generate(step).include?("staging.tfplan")
  end
  assert.call(tfplan_handoffs.empty?, "Terraform plan job hands staging.tfplan to another step")
  workflow_definition = JSON.generate(terraform_workflow)
  assert.call(!workflow_definition.include?("inputs.action"), "Terraform workflow still dispatches an apply action")
  assert.call(plan.fetch("run") == "terraform -chdir=terraform/staging plan -input=false -out=staging.tfplan", "Terraform plan step changed its reviewed command")
end

check.call("Cloudflare plan token is read-only and step-scoped") do
  terraform_job = terraform_workflow.fetch("jobs").fetch("terraform")
  job_env = terraform_job.fetch("env", {})
  validation = step_named.call(terraform_job, "Validate Terraform inputs")
  plan = step_named.call(terraform_job, "Terraform plan")
  expected_env = {"CLOUDFLARE_API_TOKEN" => "${{ secrets.CLOUDFLARE_TERRAFORM_PLAN_TOKEN }}"}
  assert.call(job_env.keys.none? { |name| name.start_with?("CLOUDFLARE_") && name.end_with?("TOKEN") }, "Cloudflare token remains job-scoped")
  assert.call(validation.fetch("env") == expected_env, "input validation does not receive only the plan token")
  assert.call(plan.fetch("env") == expected_env, "Terraform plan does not receive only the plan token")
  unrelated_steps = terraform_job.fetch("steps") - [validation, plan]
  unrelated_steps.each do |step|
    step_definition = JSON.generate(step)
    assert.call(!step_definition.include?("CLOUDFLARE_API_TOKEN"), "#{step.fetch("name", step["uses"])} receives the provider token")
    assert.call(!step_definition.include?("CLOUDFLARE_TERRAFORM_PLAN_TOKEN"), "#{step.fetch("name", step["uses"])} receives the plan secret")
  end
  workflow_definition = JSON.generate(terraform_workflow)
  assert.call(workflow_definition.scan("secrets.CLOUDFLARE_TERRAFORM_PLAN_TOKEN").length == 2, "plan secret is not scoped to exactly two steps")
  assert.call(!workflow_definition.include?("CLOUDFLARE_TERRAFORM_API_TOKEN"), "legacy shared Terraform token remains")
  assert.call(!workflow_definition.include?("CLOUDFLARE_TERRAFORM_APPLY_TOKEN"), "future apply token is exposed before an apply step exists")
end

check.call("infra CI runs the focused Terraform plan contract") do
  validate = infra_ci.fetch("jobs").fetch("validate")
  contract = step_named.call(validate, "Guard Terraform plan contracts")
  assert.call(contract.fetch("run") == "ruby tests/terraform-plan-contracts.rb", "focused Terraform plan contract is not run")
end

exit(failures.empty? ? 0 : 1)
