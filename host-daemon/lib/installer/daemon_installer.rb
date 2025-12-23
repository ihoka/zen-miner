# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Daemon installation step
  # Installs XMRig orchestrator daemon and creates XMRig symlink
  class DaemonInstaller < BaseStep
    DAEMON_SOURCE = 'xmrig-orchestrator'
    DAEMON_DEST = '/usr/local/bin/xmrig-orchestrator'
    XMRIG_SYMLINK = '/usr/local/bin/xmrig'

    def execute
      # Find source daemon (relative to install script location)
      source_daemon = find_source_daemon
      unless source_daemon
        return Result.failure(
          "Could not find xmrig-orchestrator source file",
          data: { expected_path: DAEMON_SOURCE }
        )
      end

      # Detect XMRig binary location
      result = detect_and_symlink_xmrig
      return result if result.failure?

      # Install daemon
      result = install_daemon(source_daemon)
      return result if result.failure?

      # Make daemon executable
      result = make_executable(DAEMON_DEST)
      return result if result.failure?

      Result.success("Orchestrator daemon installed")
    end

    def completed?
      file_exists?(DAEMON_DEST) && file_executable?(DAEMON_DEST)
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

    def detect_and_symlink_xmrig
      # Find xmrig binary location
      result = run_command('which', 'xmrig')

      unless result[:success]
        return Result.failure(
          "XMRig binary not found in PATH",
          data: { command: 'which xmrig' }
        )
      end

      xmrig_path = result[:stdout].strip
      logger.info "   ✓ XMRig found at: #{xmrig_path}"

      # Create symlink if needed
      if xmrig_path != XMRIG_SYMLINK
        # Check if symlink already exists and points to correct location
        if file_exists?(XMRIG_SYMLINK)
          symlink_result = run_command('readlink', '-f', XMRIG_SYMLINK)
          if symlink_result[:success] && symlink_result[:stdout].strip == xmrig_path
            logger.info "   ✓ Symlink already points to correct location"
            return Result.success("Symlink verified")
          end
        end

        # Create/update symlink
        result = run_command('sudo', 'ln', '-sf', xmrig_path, XMRIG_SYMLINK)

        if result[:success]
          logger.info "   ✓ Symlink created: #{XMRIG_SYMLINK} -> #{xmrig_path}"
          Result.success("XMRig symlink created")
        else
          Result.failure(
            "Failed to create symlink: #{result[:stderr]}",
            data: { source: xmrig_path, dest: XMRIG_SYMLINK, error: result[:stderr] }
          )
        end
      else
        logger.info "   ✓ XMRig already at standard location"
        Result.success("XMRig location verified")
      end
    end

    def install_daemon(source_path)
      result = run_command('sudo', 'cp', source_path, DAEMON_DEST)

      if result[:success]
        logger.info "   ✓ Orchestrator installed to #{DAEMON_DEST}"
        Result.success("Daemon installed")
      else
        Result.failure(
          "Failed to install daemon: #{result[:stderr]}",
          data: { source: source_path, dest: DAEMON_DEST, error: result[:stderr] }
        )
      end
    end

    def make_executable(path)
      result = run_command('sudo', 'chmod', '+x', path)

      if result[:success]
        logger.info "   ✓ Daemon made executable"
        Result.success("Daemon executable")
      else
        Result.failure(
          "Failed to make daemon executable: #{result[:stderr]}",
          data: { path: path, error: result[:stderr] }
        )
      end
    end

    def file_executable?(path)
      File.exist?(path) && File.executable?(path)
    end
  end
end
