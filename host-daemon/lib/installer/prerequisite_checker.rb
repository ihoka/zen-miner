# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Prerequisite validation step
  # Verifies sudo access, required commands, and environment variables
  class PrerequisiteChecker < BaseStep
    REQUIRED_COMMANDS = %w[sudo ruby xmrig].freeze
    REQUIRED_ENV_VARS = %w[MONERO_WALLET WORKER_ID].freeze
    MONERO_WALLET_REGEX = /^[48][0-9A-Za-z]{94}$|^4[0-9A-Za-z]{105}$/.freeze

    def execute
      # Check sudo access
      return check_sudo unless sudo_available?

      # Verify sudo privileges
      return verify_sudo_access unless can_sudo?

      logger.info "   ✓ Sudo access confirmed"

      # Check required commands
      return check_required_commands unless all_commands_exist?

      # Check and install bundler if needed
      return check_bundler unless bundler_available?

      # Validate environment variables
      return validate_env_vars unless env_vars_present?

      # Validate wallet format
      return validate_wallet_format unless wallet_format_valid?

      Result.success("All prerequisites met")
    end

    # Prerequisites always run (not idempotent)
    def completed?
      false
    end

    private

    def sudo_available?
      command_exists?('sudo')
    end

    def check_sudo
      Result.failure(
        "sudo not found. This script requires sudo to install system components",
        data: { missing_command: 'sudo' }
      )
    end

    def can_sudo?
      result = run_command('sudo', '-v')
      result[:success]
    end

    def verify_sudo_access
      Result.failure(
        "Unable to obtain sudo privileges. Please ensure your user has sudo access",
        data: { sudo_check_failed: true }
      )
    end

    def all_commands_exist?
      missing = REQUIRED_COMMANDS.reject { |cmd| command_exists?(cmd) }
      @missing_commands = missing
      missing.empty?
    end

    def check_required_commands
      REQUIRED_COMMANDS.each do |cmd|
        unless command_exists?(cmd)
          return Result.failure(
            "#{cmd} not found in PATH. Please install #{cmd} before running this script",
            data: { missing_command: cmd }
          )
        end

        # Log version info only when actually running (not in tests)
        unless ENV['RUBY_TEST_ENV']
          case cmd
          when 'ruby'
            version = `ruby --version`.strip
            logger.info "   ✓ Ruby found: #{version}"
          when 'xmrig'
            version = `xmrig --version 2>&1 | head -n1`.strip
            logger.info "   ✓ XMRig found: #{version}"
          end
        end
      end

      Result.success("All required commands found")
    end

    def bundler_available?
      # Check if bundler gem is installed
      result = run_command('gem', 'list', '-i', 'bundler')
      return true if result[:success]

      # Try to install bundler system-wide
      logger.info "   Installing bundler system-wide..."
      result = run_command('sudo', 'gem', 'install', 'bundler', '--no-document', '--no-user-install')
      return false unless result[:success]

      # Verify bundler is accessible
      test_result = run_command('ruby', '-e', "require 'bundler/inline'")
      test_result[:success]
    end

    def check_bundler
      Result.failure(
        "Bundler installation failed or not accessible",
        data: { bundler_check_failed: true }
      )
    end

    def env_vars_present?
      missing = REQUIRED_ENV_VARS.reject { |var| ENV[var] }
      @missing_env_vars = missing
      missing.empty?
    end

    def validate_env_vars
      @missing_env_vars.each do |var|
        logger.error "   ERROR: #{var} environment variable not set"
        logger.error "   Please set it before running this script:"
        logger.error "     export #{var}='your-value'"
      end

      Result.failure(
        "Missing required environment variables: #{@missing_env_vars.join(', ')}",
        data: { missing_env_vars: @missing_env_vars }
      )
    end

    def wallet_format_valid?
      wallet = ENV['MONERO_WALLET']
      wallet =~ MONERO_WALLET_REGEX
    end

    def validate_wallet_format
      wallet = ENV['MONERO_WALLET']
      logger.error "   ERROR: Invalid Monero wallet address format"
      logger.error "   Monero addresses must:"
      logger.error "     - Start with '4' (standard/integrated) or '8' (subaddress)"
      logger.error "     - Be 95 characters (standard/subaddress) or 106 characters (integrated)"
      logger.error "     - Contain only alphanumeric characters"
      logger.error ""
      logger.error "   Your address: #{wallet}"
      logger.error "   Length: #{wallet.length}"

      Result.failure(
        "Invalid Monero wallet address format",
        data: { wallet: wallet, length: wallet.length }
      )
    end
  end
end
