# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Systemd service installation step
  # Installs and enables systemd services for XMRig and orchestrator
  class SystemdInstaller < BaseStep
    SERVICES = [
      { name: 'xmrig.service', source: 'xmrig.service' },
      { name: 'xmrig-orchestrator.service', source: 'xmrig-orchestrator.service' }
    ].freeze

    SYSTEMD_DIR = '/etc/systemd/system'

    def execute
      # Find and copy service files
      SERVICES.each do |service_info|
        result = install_service_file(service_info)
        return result if result.failure?
      end

      # Reload systemd daemon
      result = reload_systemd
      return result if result.failure?

      # Enable services
      SERVICES.each do |service_info|
        result = enable_service(service_info[:name])
        return result if result.failure?
      end

      # Restart orchestrator if already running
      result = restart_orchestrator_if_running
      # Don't fail if restart fails, just log warning
      logger.warn "   ⚠ #{result.message}" if result.failure?

      Result.success("Systemd services installed and enabled")
    end

    def completed?
      # Check if all service files exist
      SERVICES.all? do |service_info|
        dest_path = File.join(SYSTEMD_DIR, service_info[:name])
        file_exists?(dest_path)
      end
    end

    private

    def find_service_source(filename)
      # Assume we're running from host-daemon/ directory or install script location
      script_dir = options[:script_dir] || File.expand_path('..', __dir__)

      # Try various possible locations
      possible_paths = [
        File.join(script_dir, filename),
        File.join(script_dir, '..', 'host-daemon', filename),
        File.join(script_dir, 'host-daemon', filename),
        File.join(Dir.pwd, 'host-daemon', filename),
        File.join(Dir.pwd, filename)
      ]

      possible_paths.find { |path| File.exist?(path) }
    end

    def install_service_file(service_info)
      source_path = find_service_source(service_info[:source])

      unless source_path
        return Result.failure(
          "Could not find service file: #{service_info[:source]}",
          data: { filename: service_info[:source] }
        )
      end

      dest_path = File.join(SYSTEMD_DIR, service_info[:name])

      result = run_command('sudo', 'cp', source_path, dest_path)

      if result[:success]
        logger.info "   ✓ Service file copied: #{service_info[:name]}"
        Result.success("Service file installed: #{service_info[:name]}")
      else
        Result.failure(
          "Failed to copy service file #{service_info[:name]}: #{result[:stderr]}",
          data: { source: source_path, dest: dest_path, error: result[:stderr] }
        )
      end
    end

    def reload_systemd
      result = run_command('sudo', 'systemctl', 'daemon-reload')

      if result[:success]
        logger.info "   ✓ Systemd daemon reloaded"
        Result.success("Systemd reloaded")
      else
        Result.failure(
          "Failed to reload systemd: #{result[:stderr]}",
          data: { error: result[:stderr] }
        )
      end
    end

    def enable_service(service_name)
      result = run_command('sudo', 'systemctl', 'enable', service_name)

      if result[:success]
        logger.info "   ✓ Service enabled: #{service_name}"
        Result.success("Service enabled: #{service_name}")
      else
        Result.failure(
          "Failed to enable service #{service_name}: #{result[:stderr]}",
          data: { service: service_name, error: result[:stderr] }
        )
      end
    end

    def restart_orchestrator_if_running
      # Check if orchestrator is running
      result = run_command('sudo', 'systemctl', 'is-active', '--quiet', 'xmrig-orchestrator')

      unless result[:success]
        # Not running, no need to restart
        return Result.success("Orchestrator not running, no restart needed")
      end

      logger.info ""
      logger.info "   Restarting orchestrator to apply updates..."

      # Restart the service
      result = run_command('sudo', 'systemctl', 'restart', 'xmrig-orchestrator')

      unless result[:success]
        return Result.failure(
          "Failed to restart orchestrator: #{result[:stderr]}",
          data: { error: result[:stderr] }
        )
      end

      # Wait a moment for service to start
      sleep(2)

      # Verify it's running
      result = run_command('sudo', 'systemctl', 'is-active', '--quiet', 'xmrig-orchestrator')

      if result[:success]
        logger.info "   ✓ Orchestrator restarted successfully"
        Result.success("Orchestrator restarted")
      else
        Result.failure(
          "Orchestrator failed to start after restart. Check logs: sudo journalctl -u xmrig-orchestrator -n 50",
          data: { check_logs: true }
        )
      end
    end
  end
end
