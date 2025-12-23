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
      # Write sudoers file securely with atomic installation
      result = write_and_install_sudoers_file
      return result if result.failure?

      Result.success("Sudo permissions configured")
    end

    def completed?
      file_exists?(SUDOERS_FILE) && file_has_mode?(SUDOERS_FILE, REQUIRED_MODE)
    end

    private

    def write_and_install_sudoers_file
      # Create temp file path with process ID for uniqueness
      temp_file_path = "#{SUDOERS_FILE}.tmp.#{Process.pid}"

      begin
        # Write content to temp file with secure permissions from the start
        # This prevents TOCTOU race condition
        File.open(temp_file_path, 'w', 0440) do |f|
          f.write(SUDOERS_CONTENT)
        end

        logger.info "   ✓ Sudoers file written to #{temp_file_path}"

        # Validate syntax before installing
        result = run_command('sudo', 'visudo', '-c', '-f', temp_file_path)
        unless result[:success]
          return Result.failure("Invalid sudoers syntax: #{result[:stderr]}")
        end

        logger.info "   ✓ Sudoers syntax validated"

        # Use sudo install for atomic move with proper ownership and permissions
        result = run_command('sudo', 'install', '-m', '0440', '-o', 'root', '-g', 'root',
                            temp_file_path, SUDOERS_FILE)

        if result[:success]
          logger.info "   ✓ Sudo permissions configured"
          Result.success("Sudoers file installed securely")
        else
          Result.failure(
            "Failed to install sudoers file: #{result[:stderr]}",
            data: { error: result[:stderr] }
          )
        end
      rescue => e
        Result.failure(
          "Failed to create sudoers file: #{e.message}",
          data: { file: temp_file_path, error: e.message }
        )
      ensure
        # Clean up temp file
        File.unlink(temp_file_path) if File.exist?(temp_file_path) rescue nil
      end
    end
  end
end
