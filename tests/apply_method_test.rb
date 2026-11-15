#!/usr/bin/env ruby
# frozen_string_literal: true

# What apply-run.yml builds for each applyMethod, and what both pipelines build
# with showPlanLog on and off. Renders the compile-time ${{ if }} blocks with
# tests/render.rb, then checks the result. Also runs the gate step's script
# for both modes.
#
#   pipeline  Plan and Apply stages; the Apply job uses applyVariableGroup and
#             environment; run-create gets savePlan from the parameter. With
#             environment '' a config_check step fails the Plan job before
#             anything is uploaded.
#   tfe       Plan stage only; nothing references environment,
#             applyVariableGroup or the Apply stage; run-create gets
#             savePlan false (a confirmable run); the gate tells the user to
#             confirm in TFE and fails on statuses that cannot be confirmed.
#   plan log  plan-log.yml follows plan-output.yml with the PLAN_ID condition
#             when showPlanLog is true and is absent when false;
#             speculative-run passes showPlanLog to pr-comment includePlanLog.
#             Defaults: on in apply-run.yml, off in speculative-run.yml (a PR
#             author could print workspace secrets through the plan text).
#   cancel    run-cancel.yml follows run-create.yml in every Plan job (on the
#             configuration version) and run-apply.yml in the pipeline-mode
#             Apply job (on $(RUN_ID)), with the default canceled() condition;
#             those jobs set cancelTimeoutInMinutes: 5.
#
# Usage: ruby tests/apply_method_test.rb
# Stdlib only. Compatible with the macOS system Ruby 2.6.

require 'open3'
require 'tmpdir'
require_relative 'render'

APPLY = 'templates/pipelines/apply-run.yml'
SPEC = 'templates/pipelines/speculative-run.yml'
PLAN_LOG_COND = "and(succeededOrFailed(), ne(variables['run.PLAN_ID'], ''))"

$failures = 0
def check(name, ok, detail = '')
  if ok
    puts "ok   #{name}"
  else
    puts "FAIL #{name} #{detail}"
    $failures += 1
  end
end

def jobs(doc)
  doc['stages'].flat_map { |s| s['jobs'] }
end

def steps(job)
  job['steps'] || job.dig('strategy', 'runOnce', 'deploy', 'steps') || []
end

def groups(job)
  (job['variables'] || []).map { |v| v['group'] }.compact
end

def tpl(steps, base)
  steps.find { |s| s['template'].to_s.end_with?("steps/#{base}") }
end

def index_of(steps, base)
  steps.index { |s| s['template'].to_s.end_with?("steps/#{base}") }
end

pipe = Render.template(APPLY, 'applyMethod' => 'pipeline', 'environment' => 'env-x')
pipe_noenv = Render.template(APPLY, 'applyMethod' => 'pipeline', 'environment' => '')
tfe = Render.template(APPLY, 'applyMethod' => 'tfe')
default = Render.template(APPLY, 'environment' => 'env-x')

# Parameters.
params = YAML.safe_load(File.read(File.join(Render::ROOT, APPLY)))['parameters']
am = params.find { |p| p['name'] == 'applyMethod' }
check('applyMethod declared, default pipeline, values pipeline and tfe',
      am && am['default'] == 'pipeline' && am['values'] == %w[pipeline tfe], am.inspect)
env = params.find { |p| p['name'] == 'environment' }
check("environment is optional (default '')", env && env.key?('default') && env['default'] == '', env.inspect)
check('default applyMethod renders the pipeline mode', default == pipe)

# pipeline mode.
check('pipeline: stages Plan and Apply', pipe['stages'].map { |s| s['stage'] } == %w[Plan Apply])
plan_job = pipe['stages'][0]['jobs'][0]
apply_job = pipe['stages'][1]['jobs'][0]
check('pipeline: Plan job uses only planVariableGroup', groups(plan_job) == ['${{ parameters.planVariableGroup }}'], groups(plan_job).inspect)
check('pipeline: Apply job uses applyVariableGroup and environment',
      groups(apply_job) == ['${{ parameters.applyVariableGroup }}'] && apply_job['environment'] == '${{ parameters.environment }}')
check('pipeline: Apply job runs run-apply.yml', !tpl(steps(apply_job), 'run-apply.yml').nil?)
check('pipeline: run-create savePlan from the parameter',
      tpl(steps(plan_job), 'run-create.yml')['parameters']['savePlan'] == '${{ parameters.savePlan }}')
check('pipeline: no config_check step when environment is set', steps(plan_job).none? { |s| s['name'] == 'config_check' })
noenv_steps = steps(pipe_noenv['stages'][0]['jobs'][0])
cc = noenv_steps.find { |s| s['name'] == 'config_check' }
check("pipeline: environment '' adds config_check as the first step", cc && noenv_steps.index(cc).zero?)
if cc
  out, status = Open3.capture2e('bash', '-c', cc['bash'])
  check('pipeline: config_check fails and names environment', !status.success? && out.include?('environment is required'), out)
end

# tfe mode.
check('tfe: one stage, Plan', tfe['stages'].map { |s| s['stage'] } == %w[Plan])
tfe_job = tfe['stages'][0]['jobs'][0]
check('tfe: Plan job uses only planVariableGroup', groups(tfe_job) == ['${{ parameters.planVariableGroup }}'])
strs = Render.strings(tfe['stages'])
%w[parameters.environment parameters.applyVariableGroup stageDependencies run-apply.yml].each do |needle|
  hits = strs.select { |s| s.include?(needle) }
  check("tfe: nothing references #{needle}", hits.empty?, hits.inspect)
end
check('tfe: run-create savePlan false (a confirmable run)',
      tpl(steps(tfe_job), 'run-create.yml')['parameters']['savePlan'] == false)
check('tfe: no config_check step', steps(tfe_job).none? { |s| s['name'] == 'config_check' })

# The gate script, run for both modes.
gate = steps(tfe_job).find { |s| s['name'] == 'gate' }
check('tfe: gate step exists and gets APPLY_METHOD', gate && gate['env']['APPLY_METHOD'] == '${{ parameters.applyMethod }}')
if gate
  run_gate = lambda do |method, status|
    env = { 'RUN_ID' => 'run-abc', 'RUN_STATUS' => status, 'RUN_LINK' => 'https://tfe.example/app/o/workspaces/w/runs/run-abc',
            'APPLY_METHOD' => method }
    Open3.capture2e(env, 'bash', '-c', gate['bash'])
  end
  out, st = run_gate.call('tfe', 'planned')
  check('tfe gate: planned says confirm in TFE and exits 0',
        st.success? && out.include?('Confirm and apply run run-abc in TFE: https://tfe.example/app/o/workspaces/w/runs/run-abc. The pipeline does not apply in this mode.'), out)
  out, st = run_gate.call('tfe', 'policy_override')
  check('tfe gate: policy_override warns to override, then confirm', st.success? && out.include?('override') && out.include?('Confirm and apply run'), out)
  out, st = run_gate.call('tfe', 'planned_and_finished')
  check('tfe gate: no changes exits 0 with nothing to confirm', st.success? && out.include?('nothing to confirm'), out)
  %w[errored applied policy_soft_failed].each do |bad|
    out, st = run_gate.call('tfe', bad)
    check("tfe gate: #{bad} fails", !st.success?, out)
  end
  out, st = run_gate.call('pipeline', 'planned')
  check('pipeline gate: planned waits for the environment approval', st.success? && out.include?('environment approval') && !out.include?('in TFE:'), out)
end

# Plan log in both pipelines.
[[APPLY, { 'applyMethod' => 'pipeline', 'environment' => 'e' }], [APPLY, { 'applyMethod' => 'tfe' }], [SPEC, {}]].each do |rel, ov|
  label = "#{File.basename(rel)} #{ov['applyMethod']}".strip
  on = Render.template(rel, ov.merge('showPlanLog' => true))
  off = Render.template(rel, ov.merge('showPlanLog' => false))
  default_job = jobs(Render.template(rel, ov)).find { |j| j['job'] == 'plan' }
  default_on = !tpl(steps(default_job), 'plan-log.yml').nil?
  if rel == SPEC
    check("#{label}: showPlanLog defaults to off on PRs", !default_on)
  else
    check("#{label}: showPlanLog defaults to on on main", default_on)
  end
  job = jobs(on).find { |j| j['job'] == 'plan' }
  st = steps(job)
  i_out = index_of(st, 'plan-output.yml')
  i_log = index_of(st, 'plan-log.yml')
  check("#{label}: plan-log.yml right after plan-output.yml", i_out && i_log == i_out + 1, [i_out, i_log].inspect)
  pl = tpl(st, 'plan-log.yml')
  check("#{label}: plan-log condition needs a PLAN_ID", pl && pl['parameters']['condition'] == PLAN_LOG_COND)
  check("#{label}: plan-log planId is $(run.PLAN_ID)", pl && pl['parameters']['planId'] == '$(run.PLAN_ID)')
  off_job = jobs(off).find { |j| j['job'] == 'plan' }
  check("#{label}: showPlanLog false drops plan-log.yml", tpl(steps(off_job), 'plan-log.yml').nil?)
  next unless rel == SPEC

  pc = tpl(st, 'pr-comment.yml')
  check("#{label}: pr-comment includePlanLog from showPlanLog", pc && pc['parameters']['includePlanLog'] == '${{ parameters.showPlanLog }}')
  i_pc = index_of(st, 'pr-comment.yml')
  check("#{label}: pr-comment after plan-log", i_pc && i_log && i_pc > i_log)
end

# Cancel handling: run-cancel right after run-create in every Plan job, on the
# configuration version, condition left at its default canceled(); in pipeline
# mode also after run-apply, on $(RUN_ID). Every job holding it sets
# cancelTimeoutInMinutes: 5.
CANCEL_DEFAULT = YAML.safe_load(File.read(File.join(Render::ROOT, 'templates/steps/run-cancel.yml')))['parameters']
                     .find { |p| p['name'] == 'condition' }['default']
check('run-cancel condition defaults to canceled()', CANCEL_DEFAULT == 'canceled()', CANCEL_DEFAULT.inspect)
[[APPLY, { 'applyMethod' => 'pipeline', 'environment' => 'e' }], [APPLY, { 'applyMethod' => 'tfe' }], [SPEC, {}]].each do |rel, ov|
  label = "#{File.basename(rel)} #{ov['applyMethod']}".strip
  doc = Render.template(rel, ov)
  job = jobs(doc).find { |j| j['job'] == 'plan' }
  st = steps(job)
  i_create = index_of(st, 'run-create.yml')
  i_cancel = index_of(st, 'run-cancel.yml')
  check("#{label}: run-cancel right after run-create", i_create && i_cancel == i_create + 1, [i_create, i_cancel].inspect)
  rc = tpl(st, 'run-cancel.yml')
  check("#{label}: run-cancel on $(upload.CONFIGURATION_VERSION_ID), no runId, default condition",
        rc && rc['parameters']['configurationVersionId'] == '$(upload.CONFIGURATION_VERSION_ID)' &&
          !rc['parameters'].key?('runId') && !rc['parameters'].key?('condition'), rc.inspect)
  check("#{label}: plan job cancelTimeoutInMinutes 5", job['cancelTimeoutInMinutes'] == 5, job['cancelTimeoutInMinutes'].inspect)
  next unless rel == APPLY

  apply_job = jobs(doc).find { |j| j['deployment'] == 'apply' }
  if ov['applyMethod'] == 'tfe'
    check('tfe: no Apply job, so no run-cancel on a run ID', apply_job.nil?)
    next
  end
  ast = steps(apply_job)
  i_apply = index_of(ast, 'run-apply.yml')
  i_acancel = index_of(ast, 'run-cancel.yml')
  check('pipeline: Apply job run-cancel right after run-apply', i_apply && i_acancel == i_apply + 1, [i_apply, i_acancel].inspect)
  arc = tpl(ast, 'run-cancel.yml')
  check('pipeline: Apply run-cancel on runId $(RUN_ID), default condition',
        arc && arc['parameters']['runId'] == '$(RUN_ID)' && !arc['parameters'].key?('condition'), arc.inspect)
  check('pipeline: Apply job cancelTimeoutInMinutes 5', apply_job['cancelTimeoutInMinutes'] == 5)
end

if $failures.positive?
  puts "FAIL apply_method_test (#{$failures})"
  exit 1
end
puts 'PASS apply_method_test'
