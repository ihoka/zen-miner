# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Sudo configuration step
  # Configures sudo permissions for the orchestrator user and deploy user
  class SudoConfigurator < BaseStep
    ORCHESTRATOR_SUDOERS_FILE = '/etc/sudoers.d/xmrig-orchestrator'
    ORCHESTRATOR_SUDOERS_CONTENT = <<~SUDOERS
      # Allow xmrig-orchestrator to manage xmrig service without password
      # Support both /bin and /usr/bin paths for compatibility
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /usr/bin/systemctl start xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /usr/bin/systemctl is-active xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /usr/bin/systemctl status xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl start xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl stop xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl restart xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl is-active xmrig
      xmrig-orchestrator ALL=(ALL) NOPASSWD: /bin/systemctl status xmrig
    SUDOERS

    DEPLOY_SUDOERS_FILE = '/etc/sudoers.d/deploy'
    DEPLOY_SUDOERS_CONTENT = <<~SUDOERS
      # Allow deploy user to update orchestrator daemon via SSH
      deploy ALL=(ALL) NOPASSWD: /usr/bin/cp /tmp/xmrig-orchestrator* /usr/local/bin/xmrig-orchestrator
      deploy ALL=(ALL) NOPASSWD: /usr/bin/chmod +x /usr/local/bin/xmrig-orchestrator
      deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart xmrig-orchestrator
      deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl is-active xmrig-orchestrator
      deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
      deploy ALL=(ALL) NOPASSWD: /usr/bin/sha256sum *
      deploy ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
    SUDOERS

    REQUIRED_MODE = '0440'

    def execute
      # Write orchestrator sudoers file
      result = write_and_install_sudoers_file(ORCHESTRATOR_SUDOERS_FILE, ORCHESTRATOR_SUDOERS_CONTENT)
      return result if result.failure?

      # Write deploy user sudoers file
      result = write_and_install_sudoers_file(DEPLOY_SUDOERS_FILE, DEPLOY_SUDOERS_CONTENT)
      return result if result.failure?

      Result.success("Sudo permissions configured for xmrig-orchestrator and deploy users")
    end

    private

    def write_and_install_sudoers_file(sudoers_file, sudoers_content)
      # Create temp file path with process ID for uniqueness
      temp_file_path = "#{sudoers_file}.tmp.#{Process.pid}"

      # Set restrictive umask before file creation
      old_umask = File.umask(0077)

      begin
        # Write content to temp file with secure permissions from the start
        # This prevents TOCTOU race condition
        File.open(temp_file_path, 'w', 0440) do |f|
          f.write(sudoers_content)
        end

        logger.info "   ✓ Sudoers file written to #{temp_file_path}"

        # Validate syntax before installing
        result = sudo_execute('visudo', '-c', '-f', temp_file_path,
                             error_prefix: "Invalid sudoers syntax")
        return result if result.failure?

        logger.info "   ✓ Sudoers syntax validated"

        # Use sudo install for atomic move with proper ownership and permissions
        result = sudo_execute('install', '-m', '0440', '-o', 'root', '-g', 'root',
                             temp_file_path, sudoers_file,
                             error_prefix: "Failed to install sudoers file")
        return result if result.failure?

        # Verify final file integrity (defense in depth)
        verify_result = sudo_execute('stat', '-c', '%U:%G:%a', sudoers_file,
                                    error_prefix: "Failed to verify sudoers file")
        return verify_result if verify_result.failure?

        actual_perms = verify_result.message.strip
        unless actual_perms == "root:root:440"
          return Result.failure(
            "Sudoers file has incorrect permissions after installation: #{actual_perms}",
            data: { expected: "root:root:440", actual: actual_perms }
          )
        end

        logger.info "   ✓ Sudo permissions configured and verified (#{sudoers_file})"
        Result.success("Sudoers file installed securely")
      rescue => e
        Result.failure(
          "Failed to create sudoers file: #{e.message}",
          data: { file: temp_file_path, error: e.message }
        )
      ensure
        # Restore original umask
        File.umask(old_umask) if old_umask
        # Clean up temp file
        File.unlink(temp_file_path) if File.exist?(temp_file_path) rescue nil
      end
    end
  end
end
