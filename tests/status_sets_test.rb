#!/usr/bin/env ruby
# frozen_string_literal: true

# The canonical run status sets, and a test that the templates use them.
#
# Usage: ruby tests/status_sets_test.rb
#
# Three places decide what a run status means. Each must match its set here:
#   1. the gate step's `case` in templates/pipelines/apply-run.yml: the union
#      of the arms marked `# APPLYABLE_MAIN` is APPLYABLE_MAIN
#   2. the Apply stage `condition` in apply-run.yml: the statuses in its in()
#      are APPLYABLE_MAIN
#   3. pr-comment.yml: `ok_states` (marked `# PLAN_OK_PR`) is PLAN_OK_PR and
#      `soft_states` (marked `# PLAN_SOFT`) is PLAN_SOFT
#
# The sets follow tfci v1.4.0 getDesiredRunStatus (internal/cloud/run.go):
# tfci run create returns once the run reaches one of these statuses.
#   always:                     policy_soft_failed, planned_and_finished,
#                               applied, post_plan_completed
#   save plan:                  planned_and_saved
#   confirmable, cost on and
#   policies off:               cost_estimated
#   confirmable, policies on:   policy_checked, policy_override
#   confirmable, neither:       planned
# A plan-only run (PR) gets the "always" list only.
#
# Stdlib only. Compatible with the macOS system Ruby 2.6.

require 'yaml'

ROOT = File.expand_path('..', __dir__)

# Plan-only runs that count as a successful PR plan.
PLAN_OK_PR = %w[planned_and_finished post_plan_completed].freeze
# Plan-only end state that needs a policy override: PR status failed,
# description "soft-mandatory policy failed: override in TFE".
PLAN_SOFT = %w[policy_soft_failed].freeze
# Main-branch run statuses that go to the approval and the Apply stage.
# policy_override also logs a warning in the gate.
APPLYABLE_MAIN = %w[planned planned_and_saved cost_estimated policy_checked post_plan_completed policy_override].freeze

TFCI_ALWAYS = %w[policy_soft_failed planned_and_finished applied post_plan_completed].freeze
TFCI_MAIN = (TFCI_ALWAYS + %w[planned_and_saved cost_estimated policy_checked policy_override planned]).freeze

$failures = 0
def check(name, ok, detail = '')
  if ok
    puts "ok   #{name}"
  else
    puts "FAIL #{name} #{detail}"
    $failures += 1
  end
end

def same_set(name, got, want)
  check(name, got.sort == want.sort,
        "got #{got.sort.inspect}, want #{want.sort.inspect} (missing #{(want - got).inspect}, extra #{(got - want).inspect})")
end

def steps_of(node)
  case node
  when Hash then node.flat_map { |k, v| k == 'steps' && v.is_a?(Array) ? v + steps_of(v) : steps_of(v) }
  when Array then node.flat_map { |v| steps_of(v) }
  else []
  end
end

def stages_of(doc)
  (doc['stages'] || []).select { |s| s.is_a?(Hash) }
end

# Sanity: the sets fit tfci's own lists.
check('PLAN_OK_PR and PLAN_SOFT are plan-only end states of tfci', (PLAN_OK_PR + PLAN_SOFT - TFCI_ALWAYS).empty?)
check('APPLYABLE_MAIN are end states of a main-branch tfci run', (APPLYABLE_MAIN - TFCI_MAIN).empty?)
check('PLAN_SOFT is never applyable', (PLAN_SOFT & APPLYABLE_MAIN).empty?)

# 1 and 2: apply-run.yml.
apply = YAML.safe_load(File.read(File.join(ROOT, 'templates/pipelines/apply-run.yml')))
gate = steps_of(apply).find { |s| s.is_a?(Hash) && s['name'] == 'gate' }
check('apply-run.yml has a step named gate', !gate.nil?)
if gate
  marked = []
  others = []
  gate['bash'].to_s.each_line do |l|
    m = l.match(/\A\s*([a-z_|\s*]+)\)\s*(#\s*(\w+))?/)
    next unless m

    pats = m[1].split('|').map(&:strip).reject(&:empty?)
    (m[3] == 'APPLYABLE_MAIN' ? marked : others).concat(pats)
  end
  same_set('gate arms marked APPLYABLE_MAIN', marked, APPLYABLE_MAIN)
  check('no APPLYABLE_MAIN status in an unmarked gate arm', (others & APPLYABLE_MAIN).empty?, (others & APPLYABLE_MAIN).inspect)
end

stage = stages_of(apply).find { |s| s['stage'] == 'Apply' }
cond = stage && stage['condition'].to_s
m = cond && cond.match(/in\(dependencies\.Plan\.outputs\['plan\.run\.RUN_STATUS'\],(.*?)\)\)\s*\z/)
check('Apply stage condition has in(dependencies.Plan.outputs[...RUN_STATUS], ...)', !m.nil?, cond.inspect)
same_set('Apply stage condition in()', m[1].scan(/'([a-z_]+)'/).flatten, APPLYABLE_MAIN) if m

# 3: pr-comment.yml.
pr = YAML.safe_load(File.read(File.join(ROOT, 'templates/steps/pr-comment.yml')))
script = steps_of(pr).map { |s| s.is_a?(Hash) ? s['bash'].to_s : '' }.join("\n")
{ 'ok_states' => ['PLAN_OK_PR', PLAN_OK_PR], 'soft_states' => ['PLAN_SOFT', PLAN_SOFT] }.each do |var, (set, want)|
  mm = script.match(/^\s*#{var}="([^"]*)"\s*#\s*#{set}\s*$/)
  check("pr-comment.yml #{var} marked # #{set}", !mm.nil?)
  same_set("pr-comment.yml #{var}", mm[1].split, want) if mm
end
check('pr-comment.yml soft description', script.include?('description="soft-mandatory policy failed: override in TFE"'))

if $failures.positive?
  puts "FAIL status_sets_test (#{$failures})"
  exit 1
end
puts 'PASS status_sets_test'
