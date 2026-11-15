#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the parameter and output tables in docs/reference.md from the
# templates, so the reference cannot drift from the code.
#
# Usage:
#   ruby tests/gen_reference.rb            print the generated block
#   ruby tests/gen_reference.rb --write    replace the block in docs/reference.md
#   ruby tests/gen_reference.rb --check    exit 1 if docs/reference.md is stale
#
# The block sits between <!-- BEGIN GENERATED --> and <!-- END GENERATED -->.
# Text outside the markers is hand-written and left alone.
#
# What is read from the templates:
#   - the summary: the first paragraph of the file's header comment
#   - parameters: name, type, default, allowed values; required = no default
#   - outputs: every `##vso[task.setvariable variable=X;isOutput=true]` in a
#     step's script, under that step's name (the template's `name` parameter
#     default when the step is named ${{ parameters.name }})
#   - for pipeline templates: stages, jobs, and the outputs of the step
#     templates they call
# Parameter descriptions come from DESCRIPTIONS below. The script fails when a
# template parameter has no description or a description names no parameter.
#
# Stdlib only. Compatible with the macOS system Ruby 2.6.

require 'yaml'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
DOC = File.join(ROOT, 'docs', 'reference.md')
BEGIN_MARK = '<!-- BEGIN GENERATED: ruby tests/gen_reference.rb --write -->'
END_MARK = '<!-- END GENERATED -->'
TEMPLATES = %w[
  templates/pipelines/speculative-run.yml
  templates/pipelines/apply-run.yml
  templates/steps/tfci.yml
  templates/steps/upload.yml
  templates/steps/run-create.yml
  templates/steps/plan-output.yml
  templates/steps/plan-log.yml
  templates/steps/run-apply.yml
  templates/steps/pr-comment.yml
  templates/steps/validate.yml
].freeze

# Keyed by "template basename:param" for a meaning specific to one template,
# or by "param" for a meaning shared by every template that declares it.
DESCRIPTIONS = {
  'workspace' => 'Workspace name in the organization.',
  'organization' => 'HCP Terraform or TFE organization name.',
  'hostname' => 'HCP Terraform or TFE hostname, set as `TF_HOSTNAME` for tfci. Required, so the token only goes to a host the caller names (`app.terraform.io` for HCP Terraform).',
  'directory' => 'Terraform configuration directory, relative to the repository root.',
  'upload.yml:directory' => 'Directory to upload, relative to `workingDirectory`.',
  'validate.yml:directory' => 'Absolute path of the Terraform configuration directory.',
  'pool' => 'Agent pool for the jobs, for example `{name: tfe-agents}`.',
  'mode' => '`docker`: run the pinned image. `native`: run the binaries on the agent PATH.',
  'image' => 'tfci image for docker mode. Pin it, ideally by digest.',
  'caBundle' => 'Absolute path on the agent to a PEM file with the private CA for TFE. Added to the system roots through `SSL_CERT_DIR`.',
  'validate.yml:caBundle' => 'Absolute path on the agent to a PEM bundle for `terraform init`. Set as `SSL_CERT_FILE`, which replaces the system roots.',
  'validateCaBundle' => 'Passed to validate.yml as `caBundle`. Set as `SSL_CERT_FILE` for `terraform init`, which replaces the system roots.',
  'variableGroup' => 'Variable group with the plan token.',
  'planVariableGroup' => 'Variable group for the Plan stage, with the plan token.',
  'applyVariableGroup' => 'Variable group for the Apply stage, with the apply token.',
  'tokenVariable' => 'Name of the secret pipeline variable that holds the token. Mapped to `TF_API_TOKEN` through `env:`.',
  'environment' => 'Azure DevOps environment for the Apply deployment job. Give it an approval and a branch control check. Required when `applyMethod` is `pipeline` (the Plan job fails at once without it); not used when it is `tfe`.',
  'applyMethod' => '`pipeline`: an Azure DevOps environment approval, then the pipeline applies with the apply token. `tfe`: a person confirms and applies the run in TFE; the run is confirmable (`savePlan` forced off), there is no Apply stage, and `environment` and `applyVariableGroup` are not used.',
  'showPlanLog' => 'Print the Terraform plan text in the job log (plan-log.yml). In speculative-run.yml it also adds a trimmed copy to the PR comment. The plan shows values not marked sensitive.',
  'maxLines' => 'Lines of the plan log kept in `outputFile`, followed by a "trimmed" line when the log is longer. The job log always gets the whole log.',
  'plan-log.yml:hostname' => 'HCP Terraform or TFE hostname (`host` or `host:port`). The API call goes to `https://<hostname>/api/v2/plans/<planId>`. Required, so the token only goes to a host the caller names.',
  'plan-log.yml:tokenVariable' => 'Name of the secret pipeline variable that holds the token. Mapped through `env:` and given to curl on stdin (`curl -K -`), never on argv.',
  'plan-log.yml:outputFile' => 'File for the trimmed plan log, read by pr-comment.yml.',
  'plan-log.yml:caBundle' => 'Absolute path on the agent to a PEM file for curl `--cacert`, used for the API call and for the log URL when it is on the same host. Replaces the system roots for those calls.',
  'planLogFile' => 'Trimmed plan log from plan-log.yml. Appended to the comment, collapsed, when it exists.',
  'includePlanLog' => 'Append `planLogFile` to the comment in a collapsed block, capped at 100,000 characters.',
  'enableValidate' => 'Run validate.yml (fmt, init and validate, tflint) before the plan.',
  'enableTflint' => 'Run tflint in validate.yml.',
  'tflintPluginInit' => 'Use the repository `.tflint.hcl` and let `tflint --init` download the plugins it declares. Off by default: tflint then ignores the repository config and uses only the bundled terraform ruleset, because on a PR the config comes from the PR author and tflint runs its plugins. Turn on only for trusted code.',
  'terraformImage' => 'Terraform image for docker mode.',
  'tflintImage' => 'tflint image for docker mode.',
  'cliConfigFile' => 'Path on the agent to a Terraform CLI config file, set as `TF_CLI_CONFIG_FILE` (for a provider mirror).',
  'name' => 'Step name. Output variables are read as `<name>.<VARIABLE>`.',
  'displayName' => 'Step display name.',
  'command' => 'tfci command, for example `run create`. Must be in `tests/tfci-v1.4.0-commands.txt`.',
  'args' => 'Flags without spaces, for example `--plan-only=true`. Split on whitespace. Never user-controlled text.',
  'textArgs' => 'Map of flag name to value. Each becomes one argument `--<name>=<value>`, passed through env.',
  'workingDirectory' => 'Directory tfci runs in (mounted at `/tfci/workspace` in docker mode).',
  'maxTimeout' => 'Set as `TF_MAX_TIMEOUT`: how long tfci waits for the run.',
  'jobTimeoutInMinutes' => '`timeoutInMinutes` of every job. Must exceed `maxTimeout`, or Azure DevOps cancels the job while tfci still waits.',
  'logLevel' => 'tfci log level, set as `TF_LOG` (`-e TF_LOG` in docker mode): empty (off), `ERROR`, `WARN`, `INFO` or `DEBUG`. Keep DEBUG out of shared logs as a precaution.',
  'savePlan' => 'Create a saved-plan run (`--save-plan`). It ends in `planned_and_saved` and does not lock the workspace until it is applied.',
  'apply-run.yml:savePlan' => 'Create the main-branch run as a saved plan (`--save-plan`). A rejected or expired approval then leaves a saved plan that does not block the workspace. Always off when `applyMethod` is `tfe`.',
  'outputFile' => "File for tfci's JSON output. Empty: `$(Agent.TempDirectory)/tfci-<name>.json`.",
  'condition' => 'Step condition.',
  'speculative' => 'Upload a speculative configuration version (plan only, for PRs).',
  'configurationVersionId' => 'Configuration version ID (`cv-...`), from upload.yml.',
  'plan-output.yml:configurationVersionId' => 'Configuration version ID, shown in the summary.',
  'planOnly' => 'Create a plan-only (speculative) run.',
  'message' => 'Run message. No user-controlled text.',
  'planId' => 'Plan ID (`plan-...`), from run-create.yml.',
  'runId' => 'Run ID (`run-...`), from run-create.yml.',
  'comment' => 'Apply comment. No user-controlled text.',
  'runLink' => 'Run URL, from run-create.yml.',
  'runStatus' => 'Run status, from run-create.yml.',
  'summaryFile' => 'Markdown summary file.',
  'pr-comment.yml:summaryFile' => 'Markdown summary to post, from plan-output.yml.',
  'add' => 'Resources to add, from plan-output.yml. For the PR status.',
  'change' => 'Resources to change, from plan-output.yml. For the PR status.',
  'destroy' => 'Resources to destroy, from plan-output.yml. For the PR status.',
  'statusContextGenre' => 'PR status context genre.',
  'statusContextName' => 'PR status context name.'
}.freeze

def load(rel)
  YAML.safe_load(File.read(File.join(ROOT, rel)))
end

def summary(rel)
  para = []
  File.foreach(File.join(ROOT, rel)) do |line|
    break unless line.start_with?('#')

    text = line.sub(/^#\s?/, '').strip
    break if text.empty? && !para.empty?

    para << text unless text.empty?
  end
  para.join(' ')
end

def fmt_default(val)
  case val
  when nil then "''"
  when '' then "`''`"
  when Hash then val.empty? ? '`{}`' : "`#{val.to_yaml.sub(/\A---\s*/, '').strip}`"
  else "`#{val}`"
  end
end

def esc(text)
  text.to_s.gsub('|', '\\|')
end

def params(rel)
  (load(rel)['parameters'] || []).map do |p|
    {
      'name' => p['name'], 'type' => p['type'] || 'string',
      'required' => !p.key?('default'), 'default' => p['default'],
      'values' => p['values']
    }
  end
end

def description(rel, name)
  DESCRIPTIONS["#{File.basename(rel)}:#{name}"] || DESCRIPTIONS[name] ||
    abort("gen_reference: no description for #{rel} parameter '#{name}'")
end

# Flattens ${{ if }} / ${{ each }} blocks in a list of steps or jobs.
def flatten(list)
  (list || []).flat_map do |item|
    if item.is_a?(Hash) && item.size == 1 && item.keys.first.to_s.start_with?('${{')
      flatten(item.values.first)
    else
      [item]
    end
  end
end

def resolve_name(raw, ps)
  return nil if raw.nil?

  raw.gsub(/\$\{\{\s*parameters\.(\w+)\s*\}\}/) do
    p = ps.find { |x| x['name'] == Regexp.last_match(1) }
    p && !p['required'] ? p['default'].to_s : "<#{Regexp.last_match(1)}>"
  end
end

# [[step_name, [VAR, ...]], ...] for a step template, with `name` overridden
# when the caller passes one.
def step_outputs(rel, name_override = nil)
  ps = params(rel)
  ps = ps.map { |p| p['name'] == 'name' ? p.merge('default' => name_override, 'required' => false) : p } if name_override
  flatten(load(rel)['steps']).each_with_object([]) do |step, acc|
    script = step['bash'] || step['script']
    next unless script.is_a?(String)

    vars = script.scan(/##vso\[task\.setvariable variable=(\w+);isOutput=true\]/).flatten.uniq
    acc << [resolve_name(step['name'], ps), vars] unless vars.empty?
  end
end

def param_table(rel)
  out = ['| Parameter | Type | Default | Required | Description |', '| --- | --- | --- | --- | --- |']
  params(rel).each do |p|
    default = p['required'] ? '' : fmt_default(p['default'])
    desc = description(rel, p['name'])
    desc += " Allowed: #{p['values'].map { |v| "`#{v}`" }.join(', ')}." if p['values']
    out << "| `#{p['name']}` | #{p['type']} | #{esc(default)} | #{p['required'] ? 'yes' : 'no'} | #{esc(desc)} |"
  end
  out
end

def step_output_section(rel)
  outs = step_outputs(rel)
  return ['Outputs: none.'] if outs.empty?

  lines = ['Outputs (step name from the `name` parameter; the default is shown):', '',
           '| Variable | Same job | Another job | Another stage |', '| --- | --- | --- | --- |']
  outs.each do |step, vars|
    vars.each do |v|
      lines << "| `#{v}` | `$(#{step}.#{v})` | `dependencies.<job>.outputs['#{step}.#{v}']` | " \
               "`stageDependencies.<stage>.<job>.outputs['#{step}.#{v}']` |"
    end
  end
  lines
end

def pipeline_section(rel)
  doc = load(rel)
  dir = File.dirname(rel)
  lines = ['Stages and jobs:', '']
  outputs = []
  # A stage inside ${{ if }} exists only when its condition holds.
  stages = (doc['stages'] || []).flat_map do |item|
    if item.is_a?(Hash) && item.size == 1 && item.keys.first.to_s.start_with?('${{')
      cond = item.keys.first.to_s[/\A\$\{\{\s*if\s+(.*?)\s*\}\}\z/, 1]
      Array(item.values.first).map { |st| st.merge('_when' => cond) }
    else
      [item]
    end
  end
  stages.each do |stage|
    flatten(stage['jobs']).each do |job|
      kind = job['deployment'] ? 'deployment' : 'job'
      jname = job['deployment'] || job['job']
      ps = params(rel)
      groups = flatten(job['variables']).select { |v| v.is_a?(Hash) && v['group'] }.map do |v|
        if (m = v['group'].match(/\$\{\{\s*parameters\.(\w+)\s*\}\}/))
          p = ps.find { |x| x['name'] == m[1] }
          "from `#{m[1]}` (default `#{p['default']}`)"
        else
          "`#{v['group']}`"
        end
      end
      conditional = job.select { |k, v| k.to_s.start_with?('${{') && v.is_a?(Hash) }.values
      depends = conditional.map { |h| h['dependsOn'] }.compact.first
      extra = []
      extra << "variable group #{groups.join(', ')}" unless groups.empty?
      extra << 'no variable group' if groups.empty?
      extra << "depends on `#{depends}` when validate is on" if depends
      extra << "environment #{job['environment'].include?('parameters.environment') ? 'from `environment`' : "`#{job['environment']}`"}" if job['environment']
      extra << "only when `#{stage['_when']}`" if stage['_when']
      lines << "- Stage `#{stage['stage']}`, #{kind} `#{jname}`: #{extra.join('; ')}."
      steps = job['steps'] || job.dig('strategy', 'runOnce', 'deploy', 'steps')
      flatten(steps).each do |s|
        next unless s['template']

        trel = File.join(dir, s['template'])
        trel = File.expand_path(trel, ROOT).sub("#{ROOT}/", '')
        step_outputs(trel, (s['parameters'] || {})['name']).each do |step, vars|
          vars.each { |v| outputs << [stage['stage'], jname, kind, step, v] }
        end
      end
    end
  end
  caption = 'Output variables set by the steps inside'
  caption += if stages.size > 1
               used = File.readlines(File.join(ROOT, rel)).reject { |l| l.lstrip.start_with?('#') }.join.scan(/outputs\['[\w.]+\.(\w+)'\]/).flatten.uniq
               ". The `#{stages[1]['stage']}` stage reads #{used.map { |v| "`#{v}`" }.join(' and ')} with the later-stage forms:"
             else
               '. The template has one stage, so the later-stage forms are for reference only:'
             end
  lines += ['', caption, '',
            '| Variable | Same job | Later stage (condition) | Later stage (job variable) |', '| --- | --- | --- | --- |']
  outputs.each do |stg, job, kind, step, v|
    if kind == 'deployment'
      lines << "| `#{v}` (job `#{job}`) | `$(#{step}.#{v})` | not generated | not generated |"
    else
      lines << "| `#{v}` (job `#{job}`) | `$(#{step}.#{v})` | `dependencies.#{stg}.outputs['#{job}.#{step}.#{v}']` | " \
               "`stageDependencies.#{stg}.#{job}.outputs['#{step}.#{v}']` |"
    end
  end
  lines
end

def generate
  out = [BEGIN_MARK, '']
  TEMPLATES.each do |rel|
    out << "## #{File.basename(rel)}" << ''
    out << "File: [`#{rel}`](../#{rel})" << ''
    out << esc(summary(rel)) << ''
    out.concat(param_table(rel)) << ''
    if rel.include?('/pipelines/')
      out.concat(pipeline_section(rel))
    else
      out.concat(step_output_section(rel))
    end
    out << ''
  end
  # Every description must name a real parameter.
  all = TEMPLATES.flat_map { |rel| params(rel).map { |p| [File.basename(rel), p['name']] } }
  DESCRIPTIONS.each_key do |k|
    tpl, name = k.include?(':') ? k.split(':', 2) : [nil, k]
    ok = all.any? { |t, n| n == name && (tpl.nil? || t == tpl) }
    abort("gen_reference: description '#{k}' matches no template parameter") unless ok
  end
  out << END_MARK
  "#{out.join("\n")}\n"
end

def splice(doc, block)
  b = doc.index(BEGIN_MARK) or abort("gen_reference: #{DOC} has no begin marker")
  e = doc.index(END_MARK) or abort("gen_reference: #{DOC} has no end marker")
  doc[0...b] + block.chomp + doc[(e + END_MARK.length)..-1]
end

block = generate
case ARGV.first
when '--write'
  File.write(DOC, splice(File.read(DOC), block))
  puts "wrote #{DOC}"
when '--check'
  current = File.read(DOC)
  expected = splice(current, block)
  if current == expected
    puts 'docs/reference.md is up to date'
  else
    tmp = File.join(Dir.tmpdir, "reference.#{$$}.md")
    File.write(tmp, expected)
    system('diff', '-u', DOC, tmp)
    File.delete(tmp)
    warn 'docs/reference.md is stale: run ruby tests/gen_reference.rb --write'
    exit 1
  end
when nil
  print block
else
  abort 'usage: ruby tests/gen_reference.rb [--write|--check]'
end
