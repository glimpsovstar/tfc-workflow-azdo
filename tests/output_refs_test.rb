#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks that every output variable a pipeline reads is one a step sets.
#
# Usage: ruby tests/output_refs_test.rb [files...]
#   With no files: templates/pipelines/*.yml and examples/*.yml, plus a
#   self-test that a wrong reference is reported.
#
# References found (comment lines are skipped):
#   $(<step>.<VAR>)
#   variables['<step>.<VAR>']
#   outputs['<step>.<VAR>'] and outputs['<job>.<step>.<VAR>']
# Each must name a step that exists in the same file, either inline with a
# `name:` or from a step template call (`- template: .../steps/x.yml`, step
# name = the `name` parameter passed, or its default), and that step's script
# must contain `##vso[task.setvariable variable=<VAR>;...isOutput=true]`.
#
# Stdlib only. Compatible with the macOS system Ruby 2.6.

require 'yaml'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
SETVAR_RE = /##vso\[task\.setvariable variable=(\w+);[^\]]*isOutput=true\]/.freeze
REF_RES = [
  /\$\(([a-z_][a-z0-9_]*)\.([A-Z][A-Z0-9_]*)\)/,
  /variables\['([a-z_][a-z0-9_]*)\.([A-Z][A-Z0-9_]*)'\]/,
  /outputs\['(?:[\w]+\.)?([a-z_][a-z0-9_]*)\.([A-Z][A-Z0-9_]*)'\]/
].freeze

def flatten(list)
  (list || []).flat_map do |item|
    if item.is_a?(Hash) && item.size == 1 && item.keys.first.to_s.start_with?('${{')
      flatten(item.values.first)
    else
      [item]
    end
  end
end

# All step-like hashes anywhere in the document.
def all_steps(node, acc = [])
  case node
  when Hash
    node.each do |k, v|
      flatten(v).each { |s| acc << s if s.is_a?(Hash) } if k == 'steps' && v.is_a?(Array)
      all_steps(v, acc)
    end
  when Array then node.each { |v| all_steps(v, acc) }
  end
  acc
end

def resolve_template(path, ref)
  local = ref.sub(/@.*\z/, '')
  return File.join(ROOT, local) if ref.include?('@') # @tfc is this repository
  return File.join(ROOT, local) if local.start_with?('/')

  File.expand_path(local, File.dirname(path))
end

# {step_name => [VAR, ...]} for a step template, with the step name taken from
# the caller's `name` parameter or the template's default.
def template_outputs(target, passed)
  doc = YAML.safe_load(File.read(target))
  params = doc['parameters'] || []
  name_default = (params.find { |p| p['name'] == 'name' } || {})['default']
  name = (passed || {})['name'] || name_default
  out = Hash.new { |h, k| h[k] = [] }
  flatten(doc['steps']).each do |st|
    next unless st.is_a?(Hash)

    script = st['bash'] || st['script']
    next unless script.is_a?(String)

    vars = script.scan(SETVAR_RE).flatten
    next if vars.empty?

    sname = st['name'].to_s.gsub(/\$\{\{\s*parameters\.name\s*\}\}/, name.to_s)
    out[sname] |= vars
  end
  out
end

def outputs_in(path)
  doc = YAML.safe_load(File.read(path))
  out = Hash.new { |h, k| h[k] = [] }
  all_steps(doc).each do |st|
    if st['template'].is_a?(String) && st['template'] =~ %r{steps/[\w-]+\.yml}
      target = resolve_template(path, st['template'])
      next unless File.file?(target)

      template_outputs(target, st['parameters']).each { |k, v| out[k] |= v }
    elsif (script = st['bash'] || st['script']).is_a?(String) && st['name']
      out[st['name']] |= script.scan(SETVAR_RE).flatten
    end
  end
  out
end

def check_file(path)
  outs = outputs_in(path)
  problems = []
  File.readlines(path).each_with_index do |line, i|
    next if line =~ /\A\s*#/

    REF_RES.each do |re|
      line.scan(re).each do |step, var|
        if !outs.key?(step)
          problems << "#{path.sub(ROOT + '/', '')}:#{i + 1} reference #{step}.#{var}: no step named '#{step}' sets output variables"
        elsif !outs[step].include?(var)
          problems << "#{path.sub(ROOT + '/', '')}:#{i + 1} reference #{step}.#{var}: step '#{step}' sets only #{outs[step].sort.join(', ')}"
        end
      end
    end
  end
  [problems, outs]
end

files = ARGV.empty? ? (Dir[File.join(ROOT, 'templates/pipelines/*.yml')] + Dir[File.join(ROOT, 'examples/*.yml')]).sort : ARGV.map { |f| File.expand_path(f) }
failures = 0
files.each do |f|
  problems, outs = check_file(f)
  if problems.empty?
    refs = outs.map { |k, v| "#{k}(#{v.size})" }.join(' ')
    puts "ok   #{f.sub(ROOT + '/', '')}: references match steps #{refs}"
  else
    puts problems.map { |p| "FAIL #{p}" }
    failures += 1
  end
end

if ARGV.empty?
  Dir.mktmpdir do |dir|
    bad = File.join(dir, 'bad.yml')
    File.write(bad, <<~YAML)
      steps:
        - template: /templates/steps/run-create.yml
          parameters:
            workspace: w
            organization: o
            hostname: h
            configurationVersionId: cv-1
        - bash: |
            set -euo pipefail
            echo "$A $B"
          env:
            A: $(run.RUN_IDX)
            B: $(nostep.RUN_ID)
    YAML
    problems, = check_file(bad)
    if problems.size == 2 && problems[0].include?('run.RUN_IDX') && problems[1].include?("no step named 'nostep'")
      puts 'ok   self-test: a wrong variable and a wrong step name are both reported'
    else
      puts "FAIL self-test: expected 2 problems, got #{problems.inspect}"
      failures += 1
    end
  end
end

if failures.positive?
  puts 'FAIL output_refs_test'
  exit 1
end
puts 'PASS output_refs_test'
