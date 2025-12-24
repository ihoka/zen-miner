# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Daemon installation step
  # Installs XMRig orchestrator daemon
  class DaemonInstaller < BaseStep
    DAEMON_SOURCE = 'xmrig-orchestrator'
    DAEMON_DEST = '/usr/local/bin/xmrig-orchestrator'

    def execute
      # Find source daemon (relative to install script location)
      source_daemon = find_source_daemon
      unless source_daemon
        return Result.failure(
          "Could not find xmrig-orchestrator source file",
          data: { expected_path: DAEMON_SOURCE }
        )
      end

      # Verify XMRig binary exists
      result = verify_xmrig_exists
      return result if result.failure?

      # Install daemon
      result = install_daemon(source_daemon)
      return result if result.failure?

      # Make daemon executable
      result = make_executable(DAEMON_DEST)
      return result if result.failure?

      Result.success("Orchestrator daemon installed")
    end

    private

    def find_source_daemon
      # Assume we're running from host-daemon/ directory or install script location
      script_dir = options[:script_dir] || File.expand_path('..', __dir__)

      # Try various possible locations
      possible_paths = [
        File.join(script_dir, DAEMON_SOURCE),
        File.join(script_dir, '..', 'host-daemon', DAEMON_SOURCE),
        File.join(script_dir, 'host-daemon', DAEMON_SOURCE),
        File.join(Dir.pwd, 'host-daemon', DAEMON_SOURCE),
        File.join(Dir.pwd, DAEMON_SOURCE)
      ]

      possible_paths.find { |path| File.exist?(path) }
    end

    def verify_xmrig_exists
      # Find xmrig binary in PATH
      result = run_command('which', 'xmrig')

      unless result[:success]
        return Result.failure(
          "XMRig binary not found in PATH",
          data: { command: 'which xmrig' }
        )
      end

      xmrig_path = result[:stdout].strip
      logger.info "   ✓ XMRig found at: #{xmrig_path}"

      # Validate the binary is actually XMRig
      version_result = run_command(xmrig_path, '--version')
      unless version_result[:success] && version_result[:stdout].include?('XMRig')
        return Result.failure(
          "Invalid XMRig binary at #{xmrig_path}: version check failed",
          data: { path: xmrig_path, output: version_result[:stdout] }
        )
      end

      logger.info "   ✓ XMRig validated"
      Result.success("XMRig binary verified")
    end

    def install_daemon(source_path)
      result = sudo_execute('cp', source_path, DAEMON_DEST,
                           error_prefix: "Failed to install daemon")
      return result if result.failure?

      logger.info "   ✓ Orchestrator installed to #{DAEMON_DEST}"
      Result.success("Daemon installed")
    end

    def make_executable(path)
      result = sudo_execute('chmod', '+x', path,
                           error_prefix: "Failed to make daemon executable")
      return result if result.failure?

      logger.info "   ✓ Daemon made executable"
      Result.success("Daemon executable")
    end

    def file_executable?(path)
      File.exist?(path) && File.executable?(path)
    end
  end
end
