# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Sudo configuration step
  # Configures sudo permissions for the orchestrator user
  class SudoConfigurator < BaseStep
    SUDOERS_FILE = '/etc/sudoers.d/xmrig-orchestrator'
    SUDOERS_CONTENT = <<~SUDOERS
      # Allow xmrig-orchestrator to manage xmrig service without password
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl start xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl stop xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl restart xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl is-active xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl status xmrig
    SUDOERS

    REQUIRED_MODE = '0440'

    def execute
      # Write sudoers file
      result = write_sudoers_file
      return result if result.failure?

      # Set correct permissions
      result = set_permissions
      return result if result.failure?

      # Validate syntax
      result = validate_sudoers_syntax
      return result if result.failure?

      Result.success("Sudo permissions configured")
    end

    def completed?
      file_exists?(SUDOERS_FILE) && file_has_mode?(SUDOERS_FILE, REQUIRED_MODE)
    end

    private

    def write_sudoers_file
      # Write to temporary file first for safety
      temp_file = "#{SUDOERS_FILE}.tmp"

      # Create the file content
      result = run_command('sudo', 'bash', '-c', "cat > #{temp_file} <<'EOF'\n#{SUDOERS_CONTENT}EOF")

      if result[:success]
        logger.info "   ✓ Sudoers file written to #{temp_file}"
        Result.success("Sudoers file written")
      else
        Result.failure(
          "Failed to write sudoers file: #{result[:stderr]}",
          data: { file: temp_file, error: result[:stderr] }
        )
      end
    end

    def set_permissions
      temp_file = "#{SUDOERS_FILE}.tmp"

      # Set permissions to 0440
      result = run_command('sudo', 'chmod', REQUIRED_MODE, temp_file)
      return Result.failure("Failed to set permissions: #{result[:stderr]}") unless result[:success]

      # Move to final location
      result = run_command('sudo', 'mv', temp_file, SUDOERS_FILE)

      if result[:success]
        logger.info "   ✓ Sudo permissions configured"
        Result.success("Permissions set correctly")
      else
        Result.failure(
          "Failed to move sudoers file to final location: #{result[:stderr]}",
          data: { error: result[:stderr] }
        )
      end
    end

    def validate_sudoers_syntax
      # Validate syntax with visudo
      result = run_command('sudo', 'visudo', '-c', '-f', SUDOERS_FILE)

      if result[:success]
        logger.info "   ✓ Sudoers syntax validated"
        Result.success("Sudoers syntax valid")
      else
        # If validation fails, remove the file
        run_command('sudo', 'rm', '-f', SUDOERS_FILE)

        Result.failure(
          "Sudoers syntax validation failed: #{result[:stderr]}",
          data: { error: result[:stderr] }
        )
      end
    end
  end
end
