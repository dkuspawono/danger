# So much was ripped direct from CocoaPods-Core - thanks!

require 'danger/danger_core/dangerfile_dsl'
require 'danger/danger_core/standard_error'

require 'danger/danger_core/plugins/dangerfile_messaging_plugin'
require 'danger/danger_core/plugins/dangerfile_import_plugin'
require 'danger/danger_core/plugins/dangerfile_git_plugin'
require 'danger/danger_core/plugins/dangerfile_github_plugin'

require 'danger/danger_core/plugins/dangerfile_github_plugin'

module Danger
  class Dangerfile
    include Danger::Dangerfile::DSL

    attr_accessor :env, :verbose, :plugins, :ui

    # @return [Pathname] the path where the Dangerfile was loaded from. It is nil
    #         if the Dangerfile was generated programmatically.
    #
    attr_accessor :defined_in_file

    # @return [String] a string useful to represent the Dangerfile in a message
    #         presented to the user.
    #
    def to_s
      'Dangerfile'
    end

    # These are the classes that are allowed to also use method_missing
    # in order to provide broader plugin support
    def self.core_plugin_classes
      [
        Danger::DangerfileMessagingPlugin,
        Danger::DangerfileImportPlugin,
        Danger::DangerfileGitHubPlugin,
        Danger::DangerfileGitPlugin
      ]
    end

    # Both of these methods exist on all objects
    # http://ruby-doc.org/core-2.2.3/Kernel.html#method-i-warn
    # http://ruby-doc.org/core-2.2.3/Kernel.html#method-i-fail
    # However, as we're using using them in the DSL, they won't
    # get method_missing called correctly.

    def warn(*args, &blk)
      method_missing(:warn, *args, &blk)
    end

    def fail(*args, &blk)
      method_missing(:fail, *args, &blk)
    end

    # When an undefined method is called, we check to see if it's something
    # that the DSLs have, then starts looking at plugins support.
    def method_missing(method_sym, *arguments, &_block)
      @core_plugins.each do |plugin|
        if plugin.public_methods(false).include?(method_sym)
          return plugin.send(method_sym, *arguments)
        end
      end
      super
    end

    def initialize(env_manager, cork_board)
      @plugins = {}
      @core_plugins = []
      @ui = cork_board

      # Triggers the core plugins
      @env = env_manager

      # Triggers local plugins from the root of a project
      Dir['./danger_plugins/*.rb'].each do |file|
        require File.expand_path(file)
      end

      refresh_plugins if env_manager.pr?
    end

    # Iterate through available plugin classes and initialize them with
    # a reference to this Dangerfile
    def refresh_plugins
      plugins = Plugin.all_plugins
      plugins.each do |klass|
        next if klass.respond_to?(:singleton_class?) && klass.singleton_class?
        plugin = klass.new(self)
        next if plugin.nil? || @plugins[klass]

        name = plugin.class.instance_name
        self.class.send(:attr_reader, name)
        instance_variable_set("@#{name}", plugin)

        @plugins[klass] = plugin
        @core_plugins << plugin if self.class.core_plugin_classes.include? klass
      end
    end
    alias init_plugins refresh_plugins

    def core_dsl_attributes
      @core_plugins.map { |plugin| { plugin: plugin, methods: plugin.public_methods(false) } }
    end

    def external_dsl_attributes
      plugins.values.reject { |plugin| @core_plugins.include? plugin } .map { |plugin| { plugin: plugin, methods: plugin.public_methods(false) } }
    end

    def method_values_for_plugin_hashes(plugin_hashes)
      plugin_hashes.flat_map do |plugin_hash|
        plugin = plugin_hash[:plugin]
        methods = plugin_hash[:methods].select { |name| plugin.method(name).parameters.empty? }

        methods.map do |method|
          case method
          when :api
            value = 'Octokit::Client'

          when :pr_json
            value = '[Skipped]'

          when :pr_body
            value = plugin.send(method)
            value = value.scan(/.{,80}/).to_a.each(&:strip!).join("\n")

          else
            value = plugin.send(method)
            # So that we either have one value per row
            # or we have [] for an empty array
            value = value.join("\n") if value.kind_of?(Array) && value.count > 0
          end

          [method.to_s, value]
        end
      end
    end

    # Iterates through the DSL's attributes, and table's the output
    def print_known_info
      rows = []
      rows += method_values_for_plugin_hashes(core_dsl_attributes)
      rows << ['---', '---']
      rows += method_values_for_plugin_hashes(external_dsl_attributes)
      rows << ['---', '---']
      rows << ['SCM', env.scm.class]
      rows << ['Source', env.ci_source.class]
      rows << ['Requests', env.request_source.class]
      rows << ['Base Commit', env.meta_info_for_base]
      rows << ['Head Commit', env.meta_info_for_head]

      params = {}
      params[:rows] = rows.each { |current| current[0] = current[0].yellow }
      params[:title] = "Danger v#{Danger::VERSION}\nDSL Attributes".green

      ui.section('Info:') do
        ui.puts
        ui.puts Terminal::Table.new(params)
        ui.puts
      end
    end

    # Parses the file at a path, optionally takes the content of the file for DI
    #
    def parse(path, contents = nil)
      print_known_info if verbose

      contents ||= File.open(path, 'r:utf-8', &:read)

      # Work around for Rubinius incomplete encoding in 1.9 mode
      if contents.respond_to?(:encoding) && contents.encoding.name != 'UTF-8'
        contents.encode!('UTF-8')
      end

      if contents.tr!('“”‘’‛', %(""'''))
        # Changes have been made
        ui.puts "Your #{path.basename} has had smart quotes sanitised. " \
          'To avoid issues in the future, you should not use ' \
          'TextEdit for editing it. If you are not using TextEdit, ' \
          'you should turn off smart quotes in your editor of choice.'.red
      end

      if contents.include?('puts')
        ui.puts 'You used `puts` in your Dangerfile. To print out text to GitHub use `message` instead'
      end

      self.defined_in_file = path
      instance_eval do
        # rubocop:disable Lint/RescueException
        begin
          # rubocop:disable Eval
          eval(contents, nil, path.to_s)
          # rubocop:enable Eval
        rescue Exception => e
          message = "Invalid `#{path.basename}` file: #{e.message}"
          raise DSLError.new(message, path, e.backtrace, contents)
        end
        # rubocop:enable Lint/RescueException
      end
    end

    def print_results
      status = status_report
      return if (status[:errors] + status[:warnings] + status[:messages] + status[:markdowns]).count == 0

      ui.section('Results:') do
        [:errors, :warnings, :messages].each do |key|
          formatted = key.to_s.capitalize + ':'
          title = case key
                  when :errors
                    formatted.red
                  when :warnings
                    formatted.yellow
                  else
                    formatted
                  end
          rows = status[key]
          print_list(title, rows)
        end

        if status[:markdowns].count > 0
          ui.section('Markdown:') do
            status[:markdowns].each do |current_markdown|
              ui.puts current_markdown
            end
          end
        end
      end
    end

    private

    def print_list(title, rows)
      ui.title(title) do
        rows.each do |row|
          ui.puts("- [ ] #{row}")
        end
      end unless rows.empty?
    end
  end
end
