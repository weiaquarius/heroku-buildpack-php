ENV['HATCHET_BUILDPACK_BASE'] = 'https://github.com/heroku/heroku-buildpack-php.git'

require 'rspec/core'
require 'hatchet'
require 'fileutils'
require 'hatchet'
require 'rspec/retry'
require 'date'
require 'json'
require 'sem_version'
require 'shellwords'
require 'excon'

ENV['RACK_ENV'] = 'test'

def product_hash(hash)
	hash.values[0].product(*hash.values[1..-1]).map{ |e| Hash[hash.keys.zip e] }
end

RSpec.configure do |config|
	config.filter_run focused: true unless ENV['IS_RUNNING_ON_CI']
	config.run_all_when_everything_filtered = true
	config.alias_example_to :fit, focused: true
	config.filter_run_excluding :requires_php_on_stack => lambda { |series| !php_on_stack?(series) }
	config.filter_run_excluding :stack => lambda { |stack| ENV['STACK'] != stack }

	config.verbose_retry       = true # show retry status in spec process
	config.default_retry_count = 2 if ENV['IS_RUNNING_ON_CI'] # retry all tests that fail again...
	# config.exceptions_to_retry = [Excon::Errors::Timeout] #... if they're caused by these exception types
	config.fail_fast = 1 if ENV['IS_RUNNING_ON_CI']

	config.expect_with :rspec do |c|
		c.syntax = :expect
	end
end

def successful_body(app, options = {})
	retry_limit = options[:retry_limit] || 100
	path = options[:path] ? "/#{options[:path]}" : ''
	Excon.get("http://#{app.name}.herokuapp.com#{path}", :idempotent => true, :expects => 200, :retry_limit => retry_limit).body
end

def expect_exit(expect: :to, operator: :eq, code: 0)
	raise ArgumentError, "Expected a block but none given" unless block_given?
	output = yield
	expect($?.exitstatus).method(expect).call(
		method(operator).call(code),
		"Expected exit code #{$?.exitstatus} #{expect} be #{operator} to #{code}; output:\n#{output}"
	)
	output # so that can be tested too
end

def expected_default_php(stack)
	case stack
		when "cedar-14", "heroku-16"
			"5.6"
		when "heroku-18"
			"7.4"
		else
			"8.0"
	end
end

def php_on_stack?(series)
	case ENV["STACK"]
		when "cedar-14"
			available = ["5.5", "5.6", "7.0", "7.1", "7.2", "7.3"]
		when "heroku-16"
			available = ["5.6", "7.0", "7.1", "7.2", "7.3", "7.4"]
		when "heroku-18"
			available = ["7.1", "7.2", "7.3", "7.4", "8.0"]
		else
			available = ["7.3", "7.4", "8.0"]
	end
	available.include?(series)
end

def new_app_with_stack_and_platrepo(*args, **kwargs)
	kwargs[:stack] ||= ENV["STACK"]
	kwargs[:config] ||= {}
	kwargs[:config]["HEROKU_PHP_PLATFORM_REPOSITORIES"] ||= ENV["HEROKU_PHP_PLATFORM_REPOSITORIES"]
	kwargs[:config].compact!
	app = Hatchet::Runner.new(*args, **kwargs)
	app.before_deploy(:append) do
		run!("cp #{__dir__}/../utils/waitforit.sh .")
	end
	app
end

def run!(cmd)
	out = `#{cmd}`
	raise "Command #{cmd} failed: #{out}" unless $?.success?
	out
end

module Hatchet
	class App
    def run(cmd_type, command = DefaultCommand, options = {}, &block)
      case command
      when Hash
        options.merge!(command)
        command = cmd_type.to_s
      when nil
        STDERR.puts "Calling App#run with an explicit nil value in the second argument is deprecated."
        STDERR.puts "You can pass in a hash directly as the second argument now.\n#{caller.join("\n")}"
        command = cmd_type.to_s
      when DefaultCommand
        command = cmd_type.to_s
      else
        command = command.to_s
      end

      allow_run_multi! if @run_multi

      run_obj = Hatchet::HerokuRun.new(
        command,
        app: self,
        retry_on_empty: options.fetch(:retry_on_empty, !ENV["HATCHET_DISABLE_EMPTY_RUN_RETRY"]),
        heroku: options[:heroku],
        raw: options[:raw],
        timeout: options.fetch(:timeout, 60)
      ).call

      return run_obj.output
    end
    def run_multi(command, options = {}, &block)
      raise "Block required" if block.nil?
      allow_run_multi!

      run_thread = Thread.new do
        run_obj = Hatchet::HerokuRun.new(
          command,
          app: self,
          retry_on_empty: options.fetch(:retry_on_empty, !ENV["HATCHET_DISABLE_EMPTY_RUN_RETRY"]),
          heroku: options[:heroku],
          raw: options[:raw],
	        timeout: options.fetch(:timeout, 60)
        ).call

        yield run_obj.output, run_obj.status
      end
      run_thread.abort_on_exception = true

      @run_multi_array << run_thread

      true
    end
	end
  class HerokuRun
    class HerokuRunEmptyOutputError < RuntimeError; end
    class HerokuRunTimeoutError < RuntimeError; end

    attr_reader :command

    def initialize(
      command,
      app: ,
      heroku: {},
      retry_on_empty: !ENV["HATCHET_DISABLE_EMPTY_RUN_RETRY"],
      raw: false,
      stderr: $stderr,
      timeout: 0)

      @raw = raw
      @app = app
      @timeout_command = `command -v timeout gtimeout | head -n1`.strip
      @timeout_seconds = timeout
      @command = build_heroku_command(command, heroku || {})
      @retry_on_empty = retry_on_empty
      @stderr = stderr
      @output = ""
      @status = nil
      @empty_fail_count = 0
      @timeout_fail_count = 0
    end

    def output
      raise "You must run `call` on this object first" unless @status
      @output
    end

    def status
      raise "You must run `call` on this object first" unless @status
      @status
    end

    def call
      begin
        execute!
      rescue HerokuRunEmptyOutputError => e
        if @retry_on_empty and (@empty_fail_count += 1) <=3
          message = String.new("Empty output from command #{@command}, retrying the command.")
          message << "\nTo disable pass in `retry_on_empty: false` or set HATCHET_DISABLE_EMPTY_RUN_RETRY=1 globally"
          message << "\nfailed_count: #{@empty_fail_count}"
          message << "\nreleases: #{@app.releases}"
          message << "\n#{caller.join("\n")}"
          @stderr.puts message
          retry
        end
      rescue HerokuRunTimeoutError => e
        if (@timeout_fail_count += 1) <= 3
          message = String.new("Command #{@command} timed out, retrying.")
          message << "\nfailed_count: #{@timeout_fail_count}"
          message << "\nreleases: #{@app.releases}"
          message << "\n#{caller.join("\n")}"
          @stderr.puts message
          retry
        end
      end

      self
    end

    private def execute!
      ShellThrottle.new(platform_api: @app.platform_api).call do |throttle|
        run_shell!
        throw(:throttle) if output.match?(/reached the API rate limit/)
      end
    end

    private def run_shell!
      puts "DEBUG #{Time.now.inspect}: Executing #{@command}..."
      @output = `#{@command}`
      @status = $?
      
      # 'timeout' will, if it terminates a program after the given timeout, return exit status 124
      # but sometimes, for tests, it's necessary to use a 'timeout' call as part of the test itself
      # for example, to check whether a web dyno boots successfully
      # this would also return status 124, and we couldn't distinguish between the two cases
      # that's why we use --preserve-status - it will report the programs exit status, even if terminated by 'timeout'
      # since 'timeout' sends a SIGTERM, the exit status reported by the shell will be 128+SIGTERM, so 143
      
      puts "DEBUG #{Time.now.inspect}: #{@command} exit status was #{@status}"
      puts "DEBUG #{Time.now.inspect}: #{@command} output was #{@output}"
      if @status.exitstatus == 143 && @timeout_seconds > 0 && !@timeout_command.empty?
        raise HerokuRunTimeoutError
      elsif @output.empty? # check for timeout first, empty second - a timed out run will likely also have no output!
        raise HerokuRunEmptyOutputError
      end
    end

    private def build_heroku_command(command, options = {})
      command = command.shellescape unless @raw

      default_options = { "app" => @app.name, "exit-code" => nil }
      heroku_options_array = (default_options.merge(options)).map do |k,v|
        # This was a bad interface decision
        next if v == Hatchet::App::SkipDefaultOption # for forcefully removing e.g. --exit-code, a user can pass this

        arg = "--#{k.to_s.shellescape}"
        arg << "=#{v.to_s.shellescape}" unless v.nil? # nil means we include the option without an argument
        arg
      end

      command = "heroku run #{heroku_options_array.compact.join(' ')} -- #{command}"
      
      if @timeout_seconds > 0
        if @timeout_command.empty?
          @stderr.puts "No 'timeout' or 'gtimeout' on $PATH, executing 'heroku run' directly..."
        else
          command = "#{@timeout_command} --preserve-status #{@timeout_seconds} #{command}"
        end
      end
      
      command
    end
  end
end
