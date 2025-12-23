# frozen_string_literal: true

require 'open3'
require_relative 'result'

module Installer
  # Base class for all installation steps
  # Provides common interface and helper methods
  class BaseStep
    attr_reader :logger, :options

    def initialize(logger:, **options)
      @logger = logger
      @options = options
    end

    # Execute the installation step
    # Must be implemented by subclasses
    # @return [Result] success or failure result
    def execute
      raise NotImplementedError, "#{self.class.name} must implement #execute"
    end

    # Check if step has already been completed (for idempotency)
    # @return [Boolean] true if step is already completed
    def completed?
      false
    end

    # Generate human-readable description from class name
    # @return [String] description of the step
    def description
      self.class.name.split('::').last.gsub(/([A-Z])/, ' \1').strip
    end

    protected

    # Run a shell command safely using Open3
    # @param cmd [Array<String>] command and arguments
    # @return [Hash] stdout, stderr, and success status
    def run_command(*cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      {
        stdout: stdout,
        stderr: stderr,
        success: status.success?
      }
    end

    # Check if a command exists in PATH
    # @param command [String] command name
    # @return [Boolean] true if command exists
    def command_exists?(command)
      # Validate command name - only alphanumeric, underscores, and hyphens
      return false unless command =~ /\A[a-z0-9_-]+\z/i
      # Use array form to prevent shell injection
      system("which", command, out: File::NULL, err: File::NULL)
    end

    # Check if a system user exists
    # @param username [String] username to check
    # @return [Boolean] true if user exists
    def user_exists?(username)
      # Strict validation for POSIX usernames
      # Must start with lowercase letter or underscore
      # Can contain lowercase letters, digits, underscores, hyphens
      # Max 32 characters (or 31 + $ for system accounts)
      return false unless username =~ /\A[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)\z/
      # Use array form to prevent shell injection
      system("id", username, out: File::NULL, err: File::NULL)
    end

    # Check if a file or directory exists
    # @param path [String] file or directory path
    # @return [Boolean] true if path exists
    def file_exists?(path)
      File.exist?(path)
    end

    # Check if a file has specific permissions
    # @param path [String] file path
    # @param mode [String] octal mode string (e.g., "0755")
    # @return [Boolean] true if file has the specified permissions
    def file_has_mode?(path, mode)
      return false unless File.exist?(path)
      actual_mode = File.stat(path).mode.to_s(8)[-4..]
      actual_mode == mode
    end

    # Execute a command with sudo, returning a Result object
    # This eliminates repeated error handling boilerplate
    # @param command [String] command to execute
    # @param args [Array<String>] command arguments
    # @param error_prefix [String] prefix for error messages
    # @return [Result] success with stdout or failure with stderr
    def sudo_execute(command, *args, error_prefix: "Command failed")
      result = run_command('sudo', command, *args)

      return Result.success(result[:stdout].strip) if result[:success]

      Result.failure(
        "#{error_prefix}: #{result[:stderr]}",
        data: {
          command: [command, *args].join(' '),
          stderr: result[:stderr],
          stdout: result[:stdout]
        }
      )
    end
  end
end
