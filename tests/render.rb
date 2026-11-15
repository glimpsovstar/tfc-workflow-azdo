# frozen_string_literal: true

# A small renderer for the compile-time conditionals in these templates, so a
# test can see what Azure DevOps would build for given parameter values.
#
# Usage:
#   require_relative 'render'
#   doc = Render.template('templates/pipelines/apply-run.yml', 'applyMethod' => 'tfe')
#
# Supported keys, the forms the templates use:
#   ${{ if eq(parameters.NAME, VALUE) }}   VALUE: 'text', true or false
#   ${{ if ne(parameters.NAME, VALUE) }}
#   ${{ else }}                            after an if, in the same mapping
# In a list, an item that is a one-key mapping with such a key is replaced by
# its list when true and dropped when false. In a mapping, the key's mapping is
# merged in when true. Anything else in ${{ }} is left as it is (values such as
# ${{ parameters.x }} are not substituted). An unknown `if` form raises, so a
# new conditional cannot pass a test by accident.
#
# Stdlib only. Compatible with the macOS system Ruby 2.6.

require 'yaml'

module Render
  ROOT = File.expand_path('..', __dir__)
  IF_RE = /\A\$\{\{\s*if\s+(eq|ne)\(\s*parameters\.(\w+)\s*,\s*('([^']*)'|true|false)\s*\)\s*\}\}\z/.freeze
  ELSE_RE = /\A\$\{\{\s*else\s*\}\}\z/.freeze

  # Parameter values: the template's defaults, then the overrides.
  def self.params(doc, overrides)
    vals = {}
    (doc['parameters'] || []).each { |p| vals[p['name']] = p['default'] if p.key?('default') }
    vals.merge(overrides)
  end

  # true or false for an `if` key, nil when the key is not an `if`.
  def self.cond(key, vals)
    k = key.to_s
    return nil unless k.start_with?('${{') && k =~ /\A\$\{\{\s*if\b/

    m = k.match(IF_RE) or raise "render.rb: unsupported conditional #{k}"
    want = m[4] || (m[3] == 'true')
    got = vals[m[2]]
    m[1] == 'eq' ? got == want : got != want
  end

  def self.else?(key)
    key.to_s =~ ELSE_RE
  end

  def self.node(obj, vals)
    case obj
    when Array then list(obj, vals)
    when Hash then mapping(obj, vals)
    else obj
    end
  end

  def self.list(items, vals)
    out = []
    last = nil
    items.each do |item|
      if item.is_a?(Hash) && item.size == 1
        k, v = item.first
        c = cond(k, vals)
        if !c.nil?
          last = c
          out.concat(list(Array(v), vals)) if c
          next
        elsif else?(k)
          raise 'render.rb: ${{ else }} without an if' if last.nil?

          out.concat(list(Array(v), vals)) unless last
          last = nil
          next
        end
      end
      last = nil
      out << node(item, vals)
    end
    out
  end

  def self.mapping(map, vals)
    out = {}
    last = nil
    map.each do |k, v|
      c = cond(k, vals)
      if !c.nil?
        last = c
        out.merge!(mapping(v, vals)) if c
      elsif else?(k)
        raise 'render.rb: ${{ else }} without an if' if last.nil?

        out.merge!(mapping(v, vals)) unless last
        last = nil
      else
        last = nil
        out[k] = node(v, vals)
      end
    end
    out
  end

  # The rendered document. The parameters list is kept as it is.
  def self.template(rel, overrides = {})
    doc = YAML.safe_load(File.read(File.join(ROOT, rel)))
    vals = params(doc, overrides)
    rendered = doc.reject { |k, _| k == 'parameters' }
    mapping(rendered, vals).merge('parameters' => doc['parameters'])
  end

  # Every string scalar in a rendered document, keys and values.
  def self.strings(obj, acc = [])
    case obj
    when Hash then obj.each { |k, v| strings(k, acc); strings(v, acc) }
    when Array then obj.each { |v| strings(v, acc) }
    when String then acc << obj
    end
    acc
  end
end
