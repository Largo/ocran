# frozen_string_literal: true

require 'rake'
Rake::TaskManager.record_task_metadata = true

module Rake
  class TUI
    VERSION = File.read(File.expand_path('../../../../../VERSION', __FILE__)).strip
    BRANDING_HEADER_DEFAULT = "== rake-tui version #{VERSION} =="
    PROMPT_QUESTION_DEFAULT = "Choose a Rake task: "
    TASK_FORMATTER_DEFAULT = lambda do |task, tasks|
      max_task_size = tasks.map(&:name_with_args).map(&:size).max + 1
      line = "rake #{task.name_with_args.ljust(max_task_size)} # #{task.comment}"
      bound = TTY::Screen.width - 6
      line.size <= bound ? line : "#{line[0..(bound - 3)]}..."
    end
  
    class << self
      # Singleton instance (if argument is specified, it is used to set instance)
      def instance(tui=nil)
        if tui.nil?
          @instance ||= new
        else
          @instance = tui
        end
      end
      
      # Runs TUI (recommended for general use)
      #
      # Optionally takes a `branding_header` to customize the branding header or take it off when set to `nil`.
      #
      # Optionally takes a `prompt_question` to customize the question for selecting a rake task.
      #
      # Optionally pass a task_formatter mapping block to
      # transform every rake task line into a different format
      # e.g. Rake::TUI.new.run { |task, tasks| task.name_with_args }
      # This makes tasks show up without `rake` prefix or `# description` suffix  
      def run(branding_header: BRANDING_HEADER_DEFAULT, prompt_question: PROMPT_QUESTION_DEFAULT, &task_formatter)
        instance.run(branding_header: branding_header, prompt_question: prompt_question, &task_formatter)
      end
    end
    
    # Initializes a new TUI object
    def initialize(tasks=Rake.application.tasks)
      if tasks.empty?
        Rake.application.init
        Rake.application.load_rakefile
        tasks = Rake.application.tasks
      end
      
      @tasks = tasks.reject {|task| task.comment.nil?}
    end
  
    # Runs TUI
    #
    # Optionally takes a `branding_header` to customize the branding header or take it off when set to `nil`.
    #
    # Optionally takes a `prompt_question` to customize the question for selecting a rake task.
    #
    # Optionally takes a `task_formatter` mapping block to
    # transform every rake task line into a different format
    # e.g. Rake::TUI.new.run { |task, tasks| task.name_with_args }
    # This makes tasks show up without `rake` prefix or `# description` suffix  
    def run(branding_header: BRANDING_HEADER_DEFAULT, prompt_question: PROMPT_QUESTION_DEFAULT, &task_formatter)
      puts branding_header unless branding_header.nil?
          
      if @tasks.empty?
        puts "No Rake tasks found!"
        puts "Exiting..."
        exit(0)
      end  
      
      require 'tty-prompt'
      
      prompt = TTY::Prompt.new

      prompt.on(:keyescape) do |event|
        puts # a new line is needed
        puts "Exiting..."
        exit(0)
      end
      
      begin      
        task_formatter ||= TASK_FORMATTER_DEFAULT
        rake_task_lines = @tasks.map {|task, tasks| task_formatter.call(task, @tasks)}
        rake_task_line = prompt.select(prompt_question, cycle: true, per_page: [TTY::Screen.height - 5, 1].max, filter: true, show_help: :always) do |list|
          list.choices rake_task_lines
          list.singleton_class.define_method(:keyspace) do |event|
            return unless filterable?
      
            if event.value = " "
              @filter << event.value
              @active = 1
            end
          end
        end
        
        selected_task = @tasks[rake_task_lines.index(rake_task_line)]
        rake_task = selected_task.name
        rake_task_arg_names = selected_task.arg_names
        rake_task_arg_values = rake_task_arg_names.map do |rake_task_arg_name|
          prompt.ask("Enter [#{rake_task_arg_name}] (default=nil):")
        end
        Rake::Task[rake_task].invoke(*rake_task_arg_values) # TODO support args
      rescue TTY::Reader::InputInterrupt => e
        # No Op
        puts # a new line is needed
        puts "Exiting..."
        exit(0)
      end  
    end
  end
end
