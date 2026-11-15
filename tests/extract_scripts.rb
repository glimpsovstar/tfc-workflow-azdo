#!/usr/bin/env ruby
# frozen_string_literal: true

# Write every bash script string in the given YAML files or directories to
# OUT_DIR as a .sh file, so shellcheck can lint it.
#
# Usage: ruby tests/extract_scripts.rb OUT_DIR paths...
#
# Azure Pipelines syntax is replaced so shellcheck sees valid bash:
#   $(Foo.Bar)   becomes "${FOO_BAR}" (or ${FOO_BAR} inside double quotes)
#   ${{ ... }}   becomes the word TEMPLATE_EXPR
# Command substitutions such as $(pwd) are left alone: a macro is a name with
# a dot, or an upper-case name.
# SC2154 (variable referenced but not assigned) is disabled in each file:
# pipeline variables arrive through env:, which shellcheck cannot see.
# Prints one line per file written: "<sh file>\t<yaml file>:<line>".

require 'fileutils'
require_relative 'check_templates'

module ExtractScripts
  MACRO_RE = /\$\(([A-Za-z_][\w.\-]*)\)/.freeze

  def self.macro?(name)
    name.include?('.') || name =~ /\A[A-Z][A-Z0-9_]*\z/
  end

  def self.var_name(name)
    name.upcase.gsub(/[^A-Z0-9_]/, '_')
  end

  # Replace macros and template expressions, tracking quote state.
  def self.to_bash(text)
    out = +''
    i = 0
    dq = false
    sq = false
    while i < text.length
      c = text[i]
      rest = text[i..-1]
      if !sq && rest.start_with?('${{')
        j = text.index('}}', i)
        j = text.length - 2 if j.nil?
        out << 'TEMPLATE_EXPR'
        i = j + 2
      elsif !sq && (m = rest.match(/\A#{MACRO_RE}/)) && macro?(m[1])
        v = var_name(m[1])
        out << (dq ? "${#{v}}" : "\"${#{v}}\"")
        i += m[0].length
      else
        if c == '\\' && !sq
          out << c << text[i + 1].to_s
          i += 2
          next
        end
        dq = !dq if c == '"' && !sq
        sq = !sq if c == "'" && !dq
        out << c
        i += 1
      end
    end
    out
  end

  def self.main(argv)
    if argv.size < 2
      warn 'usage: extract_scripts.rb OUT_DIR paths...'
      return 2
    end
    out_dir = argv.shift
    FileUtils.mkdir_p(out_dir)
    n = 0
    CheckTemplates.yaml_files(argv).each do |path|
      begin
        stream = Psych.parse_stream(File.read(path), path)
      rescue Psych::SyntaxError
        next # reported by check_templates.rb
      end
      stream.children.each do |doc|
        next if doc.root.nil?

        CheckTemplates.scripts(path, doc.root).select(&:bash).each do |s|
          n += 1
          line = s.line_for(0)
          base = format('%03d_%s_L%d.sh', n, path.gsub(%r{[^A-Za-z0-9]+}, '_'), line)
          file = File.join(out_dir, base)
          File.write(file, "#!/bin/bash\n# shellcheck disable=SC2154\n# source: #{path}:#{line}\n#{to_bash(s.text)}\n")
          puts "#{file}\t#{path}:#{line}"
        end
      end
    end
    0
  end
end

exit ExtractScripts.main(ARGV.dup) if $PROGRAM_NAME == __FILE__
