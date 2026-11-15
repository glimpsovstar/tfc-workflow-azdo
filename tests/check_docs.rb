#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the Markdown docs: README.md, CHANGELOG.md and docs/*.md
# (docs/superpowers is planning material and is skipped).
#
#   - every relative link points to an existing file, and a #fragment to an
#     existing heading in that file
#   - no em dashes
#   - no ASCII box-drawing diagrams (use Mermaid)
#
# Prints "file:line message" per problem and exits 1 if there are any.
# Stdlib only. Compatible with the macOS system Ruby 2.6.

ROOT = File.expand_path('..', __dir__)
FILES = (%w[README.md CHANGELOG.md] + Dir.glob('docs/*.md', base: ROOT)).sort

# GitHub-style heading anchor.
def anchor(heading)
  heading.strip.downcase.gsub(/[^\p{Alnum}\- _]/, '').tr(' ', '-')
end

def anchors(path)
  in_fence = false
  File.readlines(path).each_with_object([]) do |line, acc|
    in_fence = !in_fence if line.start_with?('```')
    acc << anchor(line.sub(/^#+/, '')) if !in_fence && line =~ /^#+\s/
  end
end

problems = []
FILES.each do |rel|
  path = File.join(ROOT, rel)
  in_fence = false
  File.readlines(path).each_with_index do |line, i|
    where = "#{rel}:#{i + 1}"
    problems << "#{where} em dash" if line.include?("—")
    in_fence = !in_fence if line.start_with?('```')
    problems << "#{where} box-drawing characters: use a Mermaid diagram" if line =~ /[─-╿]/
    next if in_fence

    line.scan(/\]\(([^)\s]+)\)/).flatten.each do |target|
      next if target =~ %r{\A[a-z]+://} || target.start_with?('mailto:')

      file, frag = target.split('#', 2)
      dest = file.empty? ? path : File.expand_path(file, File.dirname(path))
      unless File.exist?(dest)
        problems << "#{where} broken link #{target}"
        next
      end
      next unless frag && dest.end_with?('.md')

      problems << "#{where} no heading for ##{frag} in #{file.empty? ? rel : file}" unless anchors(dest).include?(frag)
    end
  end
end

puts problems
exit(problems.empty? ? 0 : 1)
