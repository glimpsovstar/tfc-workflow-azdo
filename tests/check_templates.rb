#!/usr/bin/env ruby
# frozen_string_literal: true

# Static checks over Azure Pipelines YAML templates.
#
# Usage: ruby tests/check_templates.rb [--manifest FILE] [paths...]
#
# Paths can be files or directories (searched for *.yml and *.yaml).
# With no paths, every YAML file in the repo is checked except tests/cases/bad.
# Prints "file:line RULE message" per violation and exits 1 if there are any.
#
# Stdlib only. Compatible with the macOS system Ruby 2.6 (Psych 3.1).
#
# Assumption: a step's `script:` runs in bash (Linux agents), so the bash rules
# apply to it. PowerShell steps and tasks are skipped by the bash-only rules.

require 'yaml'
require 'optparse'

module CheckTemplates
  REPO_ROOT = File.expand_path('..', __dir__)
  DEFAULT_MANIFEST = File.join(__dir__, 'tfci-v1.4.0-commands.txt')

  Violation = Struct.new(:file, :line, :rule, :message)

  # A script string found in the YAML, with enough context to report lines.
  Script = Struct.new(:file, :node, :key, :bash) do
    def text
      node.value.to_s
    end

    # 1-based file line of the script's line `idx` (0-based).
    # Literal (|) and folded (>) blocks start on the line after the indicator.
    # For other styles we only know the line where the scalar starts.
    def line_for(idx)
      if block?
        node.start_line + 2 + idx
      else
        node.start_line + 1
      end
    end

    def block?
      node.style == Psych::Nodes::Scalar::LITERAL || node.style == Psych::Nodes::Scalar::FOLDED
    end
  end

  # ---------- YAML helpers ----------

  def self.scalar?(node)
    node.is_a?(Psych::Nodes::Scalar)
  end

  def self.mapping?(node)
    node.is_a?(Psych::Nodes::Mapping)
  end

  def self.sequence?(node)
    node.is_a?(Psych::Nodes::Sequence)
  end

  def self.pairs(mapping)
    mapping.children.each_slice(2).to_a
  end

  def self.get(mapping, key)
    return nil unless mapping?(mapping)

    pairs(mapping).each { |k, v| return v if scalar?(k) && k.value == key }
    nil
  end

  def self.key_node(mapping, key)
    pairs(mapping).each { |k, _| return k if scalar?(k) && k.value == key }
    nil
  end

  def self.expr?(str)
    str.to_s.include?('${{')
  end

  # Walk every node. Yields (node, parent, parent_key, ctx).
  # ctx carries :task (the enclosing task name) and :inputs (true inside inputs:).
  def self.walk(node, parent = nil, parent_key = nil, ctx = {}, &blk)
    yield node, parent, parent_key, ctx
    if mapping?(node)
      task = get(node, 'task')
      pairs(node).each do |k, v|
        key = scalar?(k) ? k.value : nil
        child_ctx = ctx
        child_ctx = ctx.merge(task: task.value, inputs: true, inputs_map: v) if key == 'inputs' && task && scalar?(task)
        walk(v, node, key, child_ctx, &blk)
      end
    elsif sequence?(node)
      node.children.each { |c| walk(c, node, nil, ctx, &blk) }
    end
  end

  # Find every script string. Returns [Script].
  def self.scripts(file, root)
    found = []
    walk(root) do |node, parent, key, ctx|
      next unless scalar?(node) && mapping?(parent)
      next unless %w[script bash inlineScript].include?(key)
      # Only values, not keys: the key node is a scalar too.
      next unless get(parent, key).equal?(node)

      bash =
        if ctx[:inputs]
          task = ctx[:task].to_s
          if key == 'inlineScript'
            st = get(ctx[:inputs_map], 'scriptType')
            (st && scalar?(st) && st.value =~ /bash/i) || task =~ /\A(Bash|ShellScript)@/i ? true : false
          else
            task =~ /\A(Bash|ShellScript)@/i ? true : false
          end
        else
          %w[script bash].include?(key)
        end
      found << Script.new(file, node, key, bash)
    end
    found
  end

  # ---------- shell tokenizer ----------

  MACRO_RE = /\A\$\([A-Za-z_][\w.\-]*\)/.freeze

  # Tokenize one logical shell line. Returns [tokens, subshell_texts].
  # Tokens are [:word, text] or [:op, text]. Quotes are removed from words.
  # Text of quoted command substitutions ("$(...)") is returned for recursive scanning.
  def self.tokenize(line)
    tokens = []
    subs = []
    word = nil
    i = 0
    n = line.length
    flush = lambda do
      tokens << [:word, word] unless word.nil?
      word = nil
    end
    while i < n
      c = line[i]
      rest = line[i..-1]
      if c =~ /\s/
        flush.call
        i += 1
      elsif c == '#' && word.nil?
        break
      elsif c == '\\'
        word = (word || +'') + line[i + 1].to_s
        i += 2
      elsif c == "'"
        j = line.index("'", i + 1) || n
        word = (word || +'') + line[(i + 1)...j]
        i = j + 1
      elsif c == '"'
        word ||= +''
        i += 1
        while i < n && line[i] != '"'
          if line[i] == '\\'
            word << line[i + 1].to_s
            i += 2
          elsif line[i, 3] == '${{'
            j = line.index('}}', i) || (n - 2)
            word << line[i..(j + 1)]
            i = j + 2
          elsif line[i, 2] == '$(' && !(line[i..-1] =~ MACRO_RE)
            j = matching_paren(line, i + 1)
            subs << line[(i + 2)...j]
            word << line[i..j]
            i = j + 1
          else
            word << line[i]
            i += 1
          end
        end
        i += 1
      elsif rest.start_with?('${{')
        j = line.index('}}', i) || (n - 2)
        word = (word || +'') + line[i..(j + 1)]
        i = j + 2
      elsif rest =~ MACRO_RE
        m = Regexp.last_match(0)
        word = (word || +'') + m
        i += m.length
      elsif rest.start_with?('$(')
        flush.call
        tokens << [:op, '$(']
        i += 2
      elsif c == ')' || c == '('
        flush.call
        tokens << [:op, c]
        i += 1
      elsif rest.start_with?('&&', '||')
        flush.call
        tokens << [:op, rest[0, 2]]
        i += 2
      elsif c == '>' || c == '<'
        word = nil if word =~ /\A\d+\z/
        flush.call
        m = rest[/\A[<>]+&?/]
        tokens << [:op, 'redir']
        i += m.length
      elsif c == '|' || c == ';' || c == '&'
        flush.call
        tokens << [:op, c]
        i += 1
      else
        word = (word || +'') + c
        i += 1
      end
    end
    flush.call
    [tokens, subs]
  end

  def self.matching_paren(str, open_idx)
    depth = 0
    i = open_idx
    while i < str.length
      depth += 1 if str[i] == '('
      if str[i] == ')'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    str.length - 1
  end

  # Split tokens into simple commands (arrays of words), dropping redirections.
  def self.simple_commands(tokens)
    cmds = [[]]
    skip_next = false
    tokens.each do |type, val|
      if type == :op
        if val == 'redir'
          skip_next = true
        else
          cmds << []
        end
        next
      end
      if skip_next
        skip_next = false
        next
      end
      cmds.last << val
    end
    cmds.reject(&:empty?).map do |words|
      words = words.drop_while { |w| w =~ /\A[A-Za-z_]\w*=/ }
      words = words.drop(1) while %w[exec time command sudo].include?(words.first)
      words
    end.reject(&:empty?)
  end

  # Join backslash continuations. Returns [[logical_line, first_index], ...].
  def self.logical_lines(text)
    out = []
    buf = nil
    start = 0
    text.split("\n", -1).each_with_index do |l, idx|
      if buf.nil?
        buf = +''
        start = idx
      end
      if l =~ /\\\s*\z/
        buf << l.sub(/\\\s*\z/, '') << ' '
      else
        buf << l
        out << [buf, start]
        buf = nil
      end
    end
    out << [buf, start] unless buf.nil?
    out
  end

  # Every simple command in a script, recursing into quoted command substitutions.
  # Yields (words, line_index).
  def self.each_command(text)
    logical_lines(text).each do |line, idx|
      queue = [line]
      until queue.empty?
        tokens, subs = tokenize(queue.shift)
        simple_commands(tokens).each { |w| yield w, idx }
        queue.concat(subs)
      end
    end
  end

  # ---------- docker ----------

  DOCKER_VALUE_OPTS = %w[
    -e --env --env-file -v --volume -w --workdir --name --entrypoint --network --net
    -u --user --mount -p --publish --platform -l --label --label-file --add-host --cpus
    -m --memory --hostname -h --dns --cap-add --cap-drop --device --security-opt
    --ulimit --restart --pull --log-driver --log-opt --tmpfs --ipc --pid --gpus
    --cidfile --stop-signal --stop-timeout --health-cmd --shm-size --link --expose
    --volumes-from --group-add --runtime --isolation --memory-swap --cpu-shares
  ].freeze

  # Returns [verb, image, rest] for `docker run|pull`, else nil.
  def self.docker_parts(words)
    return nil unless words[0] == 'docker'

    args = words[1..-1]
    args = args[1..-1] if %w[container image].include?(args[0])
    verb = args[0]
    return nil unless %w[run pull].include?(verb)

    i = 1
    while i < args.length && args[i].start_with?('-')
      opt = args[i]
      i += 1
      i += 1 if !opt.include?('=') && DOCKER_VALUE_OPTS.include?(opt)
    end
    return nil if i >= args.length

    [verb, args[i], args[(i + 1)..-1] || []]
  end

  # nil if the image reference is pinned; otherwise the reason.
  def self.image_problem(img)
    img = img.to_s.strip
    return nil if img.empty?
    return 'uses the :latest tag' if img.end_with?(':latest')
    return nil if img.include?('$') # parameter, variable or macro: checked where it is defined
    return nil if img.include?('@sha256:')

    last = img.split('/').last
    return nil if last.include?(':')

    'has no tag (resolves to :latest)'
  end

  # ---------- tfci manifest ----------

  class Manifest
    attr_reader :commands, :globals

    def initialize(path)
      @commands = {}
      @globals = []
      File.readlines(path).each do |l|
        l = l.chomp
        next if l.strip.empty? || l.start_with?('#')

        name, flags = l.split("\t", 2)
        list = flags.to_s.split(',').map(&:strip).reject(&:empty?)
        if name == 'global'
          @globals = list
        else
          @commands[name] = list
        end
      end
    end

    def all_command_flags
      @commands.values.flatten.uniq
    end
  end

  # ---------- checker ----------

  class Checker
    attr_reader :violations

    def initialize(manifest)
      @manifest = manifest
      @violations = []
      @decl_cache = {}
    end

    def add(file, line, rule, msg)
      @violations << Violation.new(file, line, rule, msg)
    end

    def check_file(path)
      text = File.read(path)
      begin
        stream = Psych.parse_stream(text, path)
      rescue Psych::SyntaxError => e
        add(path, e.line, 'yaml-parse', e.problem.to_s + (e.context ? " #{e.context}" : ''))
        return
      end
      @raw_lines = text.split("\n", -1)
      stream.children.each do |doc|
        root = doc.root
        next if root.nil?

        check_templates_refs(path, root)
        check_images(path, root)
        CheckTemplates.scripts(path, root).each { |s| check_script(s) }
      end
    end

    # ----- templates and parameters -----

    def check_templates_refs(path, root)
      CheckTemplates.walk(root) do |node, parent, key, _ctx|
        next unless CheckTemplates.mapping?(node)

        if key == 'extends'
          check_template_ref(path, node)
        elsif CheckTemplates.sequence?(parent) && CheckTemplates.get(node, 'template')
          check_template_ref(path, node)
        end
      end
    end

    def check_template_ref(path, ref)
      tnode = CheckTemplates.get(ref, 'template')
      return unless tnode && CheckTemplates.scalar?(tnode)

      tpath = tnode.value.to_s
      line = tnode.start_line + 1
      return if CheckTemplates.expr?(tpath)

      if tpath.include?('../')
        add(path, line, 'no-parent-template-path', "template path '#{tpath}' uses ../; reference templates from the repo root or a repository resource")
      end
      check_tfci_params(path, ref) if File.basename(tpath.sub(/@.*\z/, '')) == 'tfci.yml'
      return if tpath.include?('@') # repository resource reference

      target = if tpath.start_with?('/')
                 File.join(REPO_ROOT, tpath)
               else
                 File.expand_path(tpath, File.dirname(File.expand_path(path)))
               end
      unless File.file?(target)
        add(path, line, 'param-crosscheck', "template '#{tpath}' not found")
        return
      end
      decls = declarations(target)
      return if decls.nil?

      passed = CheckTemplates.get(ref, 'parameters')
      passed_names = []
      has_expr_key = false
      if CheckTemplates.mapping?(passed)
        CheckTemplates.pairs(passed).each do |k, v|
          next unless CheckTemplates.scalar?(k)

          name = k.value.to_s
          if CheckTemplates.expr?(name)
            has_expr_key = true
            next
          end
          passed_names << name
          kline = k.start_line + 1
          d = decls[name]
          if d.nil?
            add(path, kline, 'param-crosscheck', "parameter '#{name}' is not declared by '#{tpath}'")
            next
          end
          if %w[boolean number].include?(d[:type]) && CheckTemplates.scalar?(v) && v.value.to_s.include?('$(')
            add(path, kline, 'no-macro-in-typed-param',
                "runtime macro '#{v.value}' passed to #{d[:type]} parameter '#{name}' of '#{tpath}'; macros expand at runtime, after the type check")
          end
        end
      end
      return if has_expr_key

      decls.each do |name, d|
        next if d[:has_default] || passed_names.include?(name)

        add(path, line, 'param-crosscheck', "required parameter '#{name}' of '#{tpath}' is not passed")
      end
    end

    # ----- calls to the tfci wrapper template (tfci.yml) -----

    PLACEHOLDER_RE = /\$\{\{.*?\}\}|\$\([^)]*\)/.freeze
    TEXT_ARG_KEY_RE = /\A[A-Za-z_]+\z/.freeze

    # The wrapper runs `tfci <command> --json <args> <textArgs>`. Check that the
    # command exists and that every flag in args and every textArgs key is a
    # flag of that command. ${{ }} and $() placeholders in args are ignored.
    def check_tfci_params(path, ref)
      params = CheckTemplates.get(ref, 'parameters')
      return unless CheckTemplates.mapping?(params)

      cnode = CheckTemplates.get(params, 'command')
      return unless cnode && CheckTemplates.scalar?(cnode)

      cmd = cnode.value.to_s.strip.split(/\s+/).join(' ')
      return if cmd.include?('$') # supplied by a parameter or variable

      line = cnode.start_line + 1
      unless @manifest.commands.key?(cmd)
        add(path, line, 'tfci-param-command', "unknown tfci command '#{cmd}' (known: #{@manifest.commands.keys.join(', ')})")
        return
      end
      allowed = @manifest.commands[cmd] | ['json']

      anode = CheckTemplates.get(params, 'args')
      if anode && CheckTemplates.scalar?(anode)
        anode.value.to_s.gsub(PLACEHOLDER_RE, ' ').split(/\s+/).each do |w|
          next unless w =~ /\A--?[A-Za-z]/

          check_tfci_param_flag(path, anode.start_line + 1, cmd, flag_name(w), allowed, 'args')
        end
      end

      tnode = CheckTemplates.get(params, 'textArgs')
      return unless CheckTemplates.mapping?(tnode)

      CheckTemplates.pairs(tnode).each do |k, _|
        next unless CheckTemplates.scalar?(k)

        name = k.value.to_s
        next if CheckTemplates.expr?(name)

        kline = k.start_line + 1
        unless name =~ TEXT_ARG_KEY_RE
          add(path, kline, 'tfci-param-command', "textArgs key '#{name}' must be letters and underscores only (it becomes an env var name)")
          next
        end
        check_tfci_param_flag(path, kline, cmd, name, allowed, 'textArgs')
      end
    end

    def check_tfci_param_flag(path, line, cmd, name, allowed, where)
      return if allowed.include?(name)

      msg = if @manifest.globals.include?(name)
              "tfci global flag '--#{name}' in #{where}: the wrapper sets it from its own parameters"
            else
              "unknown flag '--#{name}' in #{where} for 'tfci #{cmd}' (flags: #{allowed.sort.join(', ')})"
            end
      add(path, line, 'tfci-param-command', msg)
    end

    # {name => {type:, has_default:}} or nil if the target does not parse.
    def declarations(target)
      return @decl_cache[target] if @decl_cache.key?(target)

      decls = {}
      begin
        stream = Psych.parse_stream(File.read(target), target)
      rescue Psych::SyntaxError
        @decl_cache[target] = nil
        return nil
      end
      root = stream.children.first && stream.children.first.root
      params = CheckTemplates.get(root, 'parameters')
      if CheckTemplates.sequence?(params)
        params.children.each do |p|
          next unless CheckTemplates.mapping?(p)

          n = CheckTemplates.get(p, 'name')
          next unless n && CheckTemplates.scalar?(n)

          t = CheckTemplates.get(p, 'type')
          decls[n.value.to_s] = {
            type: t && CheckTemplates.scalar?(t) ? t.value.to_s : 'string',
            has_default: !CheckTemplates.key_node(p, 'default').nil?
          }
        end
      elsif CheckTemplates.mapping?(params)
        # Old syntax: name: default. Every parameter has a default.
        CheckTemplates.pairs(params).each do |k, _|
          decls[k.value.to_s] = { type: 'object', has_default: true } if CheckTemplates.scalar?(k)
        end
      end
      @decl_cache[target] = decls
    end

    # ----- images in YAML keys and parameter defaults -----

    def check_images(path, root)
      CheckTemplates.walk(root) do |node, parent, key, _ctx|
        next unless CheckTemplates.scalar?(node) && CheckTemplates.mapping?(parent)
        next unless CheckTemplates.get(parent, key).equal?(node)

        val = node.value.to_s
        line = node.start_line + 1
        if key == 'image'
          prob = CheckTemplates.image_problem(val)
          add(path, line, 'no-latest-image', "image '#{val}' #{prob}") if prob
        elsif key == 'container' && CheckTemplates.get(parent, 'image').nil? && val =~ %r{[/:]}
          prob = CheckTemplates.image_problem(val)
          add(path, line, 'no-latest-image', "container image '#{val}' #{prob}") if prob
        end
      end
      params = CheckTemplates.get(root, 'parameters')
      return unless CheckTemplates.sequence?(params)

      params.children.each do |p|
        next unless CheckTemplates.mapping?(p)

        n = CheckTemplates.get(p, 'name')
        d = CheckTemplates.get(p, 'default')
        next unless n && d && CheckTemplates.scalar?(n) && CheckTemplates.scalar?(d)

        val = d.value.to_s
        next unless n.value.to_s =~ /image/i || val.end_with?(':latest')

        prob = CheckTemplates.image_problem(val)
        add(path, d.start_line + 1, 'no-latest-image', "parameter '#{n.value}' default image '#{val}' #{prob}") if prob
      end
    end

    # ----- scripts -----

    SECRET_NAME_RE = /TOKEN|SECRET|PASSWORD|KEY/i.freeze
    PAT_RE = /(\A|[._])PAT([._]|\z)/i.freeze
    USER_MACRO_RE = /\A(System\.PullRequest\.|Build\.SourceBranch|Build\.SourceVersionMessage\z|Build\.RequestedFor)/i.freeze
    TEMPLATE_IF_RE = /\$\{\{\s*(if|elseif|else|each)\b/.freeze
    STRICT_RE = /\Aset\s+-E?euo\s+pipefail\s*(;|#|\z)/.freeze

    def check_script(script)
      file = script.file
      text = script.text
      lines = text.split("\n", -1)

      lines.each_with_index do |l, idx|
        if (m = l.match(TEMPLATE_IF_RE))
          add(file, line_of(script, idx, m[0]), 'no-template-if-in-script',
              "template expression '#{m[0]}' inside a #{script.key} string is plain text there; use a conditional step or inline the value")
        end
        l.scan(/\$\(([A-Za-z_][\w.\-]*)\)/).flatten.each do |name|
          tok = "$(#{name})"
          if name =~ SECRET_NAME_RE || name =~ PAT_RE
            add(file, line_of(script, idx, tok), 'no-secret-macro-in-script',
                "secret-looking macro #{tok} in a script body; map it with env: and use the shell variable")
          end
          if name =~ USER_MACRO_RE
            add(file, line_of(script, idx, tok), 'no-user-macro-in-script',
                "user-controlled macro #{tok} expanded into a script; map it with env: and quote the shell variable")
          end
        end
      end

      if script.bash
        first = lines.map(&:strip).find { |l| !l.empty? && !l.start_with?('#') }
        unless first.nil? || first =~ STRICT_RE
          idx = lines.index { |l| l.strip == first } || 0
          add(file, script.line_for(idx), 'strict-bash', "bash script does not start with 'set -euo pipefail' (first line: '#{first[0, 60]}')")
        end
      end

      CheckTemplates.each_command(text) do |words, idx|
        check_set_x(script, words, idx)
        check_docker(script, words, idx)
        check_tfci(script, words, idx)
      end
    end

    def check_set_x(script, words, idx)
      return unless words[0] == 'set'

      xtrace = words[1..-1].each_with_index.any? do |w, i|
        w =~ /\A-[A-Za-z]*x/ || (w == '-o' && words[i + 2] == 'xtrace')
      end
      add(script.file, line_of(script, idx, 'set'), 'no-set-x', "'#{words.join(' ')}' traces commands and can print secrets") if xtrace
    end

    def check_docker(script, words, idx)
      parts = CheckTemplates.docker_parts(words)
      return unless parts

      verb, image, rest = parts
      prob = CheckTemplates.image_problem(image)
      add(script.file, line_of(script, idx, image), 'no-latest-image', "docker #{verb} image '#{image}' #{prob}") if prob
      check_tfci_args(script, rest[1..-1] || [], idx) if verb == 'run' && rest[0] == 'tfci'
    end

    def check_tfci(script, words, idx)
      return unless words[0] == 'tfci' || words[0].to_s.end_with?('/tfci')

      check_tfci_args(script, words[1..-1], idx)
    end

    def flag_name(arg)
      arg.sub(/\A--?/, '').split('=', 2).first
    end

    def check_tfci_args(script, args, idx)
      file = script.file
      line = line_of(script, idx, 'tfci ')
      globals = @manifest.globals
      i = 0
      while i < args.length && args[i].start_with?('-')
        name = flag_name(args[i])
        return if %w[h help].include?(name)

        unless globals.include?(name)
          hint = if @manifest.all_command_flags.include?(name)
                   "; --#{name} is a command flag, put it after the command"
                 else
                   ''
                 end
          add(file, line, 'tfci-command-exists', "unknown tfci global flag '#{args[i]}' (global flags: #{globals.join(', ')})#{hint}")
        end
        # Global flags all take a value; skip it when not given as --flag=value.
        i += 1 if !args[i].include?('=') && globals.include?(name)
        i += 1
      end

      words = []
      j = i
      while j < args.length && words.length < 3 && !args[j].start_with?('-')
        words << args[j]
        j += 1
      end
      return if words.first.to_s.start_with?('$') # command supplied by a parameter or variable
      return if words.empty? && i.positive? # only global flags, already reported

      cmd = nil
      words.length.downto(1) do |k|
        cand = words[0, k].join(' ')
        if @manifest.commands.key?(cand)
          cmd = cand
          i += k
          break
        end
      end
      if cmd.nil?
        shown = words.empty? ? '(none)' : words.join(' ')
        add(file, line, 'tfci-command-exists', "unknown tfci command '#{shown}' (known: #{@manifest.commands.keys.join(', ')})")
        return
      end

      allowed = @manifest.commands[cmd]
      args[i..-1].each do |a|
        next unless a =~ /\A--?[A-Za-z]/

        name = flag_name(a)
        next if allowed.include?(name)

        msg = if globals.include?(name)
                "tfci global flag '--#{name}' must go before the command, not after '#{cmd}'"
              else
                "unknown flag '--#{name}' for 'tfci #{cmd}' (flags: #{allowed.join(', ')})"
              end
        add(file, line, 'tfci-command-exists', msg)
      end
    end

    # Line of `needle` near script line idx. Block scalars map directly; for
    # other scalars, scan the raw file from where the scalar starts.
    def line_of(script, idx, needle)
      if script.block?
        # Search the logical line (it may span several physical lines).
        lines = script.text.split("\n", -1)
        j = idx
        while j < lines.length
          return script.line_for(j) if lines[j].include?(needle)
          break unless lines[j] =~ /\\\s*\z/

          j += 1
        end
        return script.line_for(idx)
      end

      start = script.node.start_line
      (start...[@raw_lines.length, start + 200].min).each do |i|
        return i + 1 if @raw_lines[i].include?(needle)
      end
      start + 1
    end
  end

  def self.yaml_files(paths)
    paths.flat_map do |p|
      if File.directory?(p)
        Dir.glob(File.join(p, '**', '*.{yml,yaml}')).sort
      elsif File.file?(p)
        [p]
      else
        warn "check_templates: no such file or directory: #{p}"
        exit 2
      end
    end
  end

  def self.default_paths
    Dir.chdir(REPO_ROOT) do
      Dir.glob('**/*.{yml,yaml}').reject { |p| p.start_with?('tests/cases/bad/') }.sort
    end.map { |p| File.join(REPO_ROOT, p) }
  end

  def self.relative(path)
    abs = File.expand_path(path)
    pwd = Dir.pwd + '/'
    abs.start_with?(pwd) ? abs[pwd.length..-1] : path
  end

  def self.main(argv)
    manifest_path = DEFAULT_MANIFEST
    OptionParser.new do |o|
      o.banner = 'Usage: check_templates.rb [--manifest FILE] [paths...]'
      o.on('--manifest FILE', 'tfci command manifest') { |v| manifest_path = v }
    end.parse!(argv)

    files = argv.empty? ? default_paths : yaml_files(argv)
    checker = Checker.new(Manifest.new(manifest_path))
    files.each { |f| checker.check_file(relative(f)) }
    vs = checker.violations.uniq { |v| [v.file, v.line, v.rule, v.message] }
    vs.sort_by { |v| [v.file, v.line.to_i, v.rule] }.each do |v|
      puts "#{v.file}:#{v.line} #{v.rule} #{v.message}"
    end
    vs.empty? ? 0 : 1
  end
end

exit CheckTemplates.main(ARGV.dup) if $PROGRAM_NAME == __FILE__
