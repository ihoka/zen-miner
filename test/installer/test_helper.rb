# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

# Set test environment flag to skip version checks
ENV['RUBY_TEST_ENV'] = 'true'

# Load installer modules
require_relative '../../host-daemon/lib/installer/result'
require_relative '../../host-daemon/lib/installer/base_step'

module InstallerTestHelpers
  # Mock all system interactions at once
  # @param system_commands [Hash] mapping of system() command patterns to boolean results
  # @param open3_commands [Hash] mapping of Open3.capture3 patterns to responses
  def mock_all(system_commands: {}, open3_commands: {})
    # Stub system() calls
    system_stub = lambda do |cmd, *rest|
      # Handle both forms: system("cmd") and system("cmd", arg1, arg2...)
      full_cmd = [cmd, *rest].join(' ')

      system_commands.each do |pattern, return_value|
        if pattern.is_a?(Regexp)
          return return_value if full_cmd =~ pattern
        else
          return return_value if full_cmd.include?(pattern)
        end
      end
      false # Default to command not found
    end

    # Stub Open3.capture3 calls
    open3_stub = lambda do |*args|
      # SECURITY: Verify commands are called with array form, not string interpolation
      # This prevents shell injection vulnerabilities
      if args.length == 1 && args[0].is_a?(String) && args[0].include?(' ')
        raise SecurityError, "Command called with string interpolation instead of array form: #{args[0]}\n" \
                           "Use: run_command('sudo', 'command', arg1, arg2)\n" \
                           "Not: run_command('sudo command #{arg1} #{arg2}')"
      end

      cmd_string = args.join(' ')
      open3_commands.each do |pattern, response|
        if pattern.is_a?(Regexp)
          return [response[:stdout] || "", response[:stderr] || "", mock_status(response[:success] != false)] if cmd_string =~ pattern
        else
          return [response[:stdout] || "", response[:stderr] || "", mock_status(response[:success] != false)] if cmd_string.include?(pattern)
        end
      end
      ["", "Command not mocked: #{cmd_string}", mock_status(false)]
    end

    # Apply both stubs simultaneously
    # Define method on Installer::BaseStep to override system()
    Installer::BaseStep.stub :system, system_stub do
      Open3.stub :capture3, open3_stub do
        yield
      end
    end
  end

  # Mock a command execution via Open3.capture3
  # @param cmd_pattern [String, Regexp] pattern to match command
  # @param stdout [String] stdout to return
  # @param stderr [String] stderr to return
  # @param success [Boolean] whether command succeeds
  def mock_command(cmd_pattern, stdout: "", stderr: "", success: true)
    Open3.stub :capture3, lambda { |*args|
      # SECURITY: Verify commands are called with array form, not string interpolation
      if args.length == 1 && args[0].is_a?(String) && args[0].include?(' ')
        raise SecurityError, "Command called with string interpolation instead of array form: #{args[0]}"
      end

      cmd_string = args.join(' ')
      if cmd_pattern.is_a?(Regexp)
        return [stdout, stderr, mock_status(success)] if cmd_string =~ cmd_pattern
      else
        return [stdout, stderr, mock_status(success)] if cmd_string.include?(cmd_pattern)
      end
      raise "Unexpected command: #{cmd_string}"
    } do
      yield
    end
  end

  # Mock system() calls
  # @param result [Boolean, Hash] result to return or mapping of commands to results
  def mock_system(result)
    if result.is_a?(Hash)
      Kernel.stub :system, lambda { |*args|
        cmd = args.join(' ')
        result.each do |pattern, return_value|
          if pattern.is_a?(Regexp)
            return return_value if cmd =~ pattern
          else
            return return_value if cmd.include?(pattern)
          end
        end
        false # Default return value
      } do
        yield
      end
    else
      Kernel.stub :system, result do
        yield
      end
    end
  end

  # Mock File.exist? calls
  # @param paths [Array<String>, Hash] paths that exist or mapping of paths to existence
  def mock_file_exists(paths)
    if paths.is_a?(Hash)
      File.stub :exist?, lambda { |path| paths.fetch(path, false) } do
        yield
      end
    else
      File.stub :exist?, lambda { |path| paths.include?(path) } do
        yield
      end
    end
  end

  # Mock File.stat for permission checks
  # @param permissions [Hash] mapping of paths to octal mode strings
  def mock_file_stat(permissions)
    File.stub :stat, lambda { |path|
      mode = permissions[path]
      raise "No mock permissions defined for #{path}" unless mode

      stat_mock = Object.new
      stat_mock.define_singleton_method(:mode) { mode.to_i(8) }
      stat_mock
    } do
      yield
    end
  end

  # Temporarily set environment variables
  # @param vars [Hash] environment variables to set
  def with_env(vars)
    original = {}
    vars.each do |key, value|
      original[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    original.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  # Create a temporary directory for testing
  # @yield [String] path to temporary directory
  def with_temp_dir
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  # Create a mock logger for testing
  # @return [Logger] logger that stores messages in memory
  def mock_logger
    logger = Object.new
    messages = []

    logger.define_singleton_method(:info) { |msg| messages << [:info, msg] }
    logger.define_singleton_method(:warn) { |msg| messages << [:warn, msg] }
    logger.define_singleton_method(:error) { |msg| messages << [:error, msg] }
    logger.define_singleton_method(:debug) { |msg| messages << [:debug, msg] }
    logger.define_singleton_method(:messages) { messages }

    logger
  end

  private

  # Create a mock Process::Status object
  # @param success [Boolean] whether the process succeeded
  # @return [Object] mock status object
  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status.define_singleton_method(:exitstatus) { success ? 0 : 1 }
    status
  end
end

# Include helpers in all test cases
class Minitest::Test
  include InstallerTestHelpers
end
