# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Logrotate configuration step
  # Configures log rotation for XMRig logs
  class LogrotateConfigurator < BaseStep
    LOGROTATE_FILE = '/etc/logrotate.d/xmrig'
    LOGROTATE_CONFIG = <<~LOGROTATE
      /var/log/xmrig/*.log {
          daily
          rotate 7
          compress
          missingok
          notifempty
          create 0640 xmrig xmrig
      }
    LOGROTATE

    def execute
      # Write logrotate configuration
      result = write_logrotate_file
      return result if result.failure?

      logger.info "   ✓ Logrotate configured (7 day retention)"
      Result.success("Logrotate configured")
    end

    private

    def write_logrotate_file
      # Write configuration to file
      result = run_command('sudo', 'bash', '-c', "cat > #{LOGROTATE_FILE} <<'EOF'\n#{LOGROTATE_CONFIG}EOF")

      if result[:success]
        logger.info "   ✓ Logrotate file written to #{LOGROTATE_FILE}"
        Result.success("Logrotate configuration written")
      else
        Result.failure(
          "Failed to write logrotate configuration: #{result[:stderr]}",
          data: { file: LOGROTATE_FILE, error: result[:stderr] }
        )
      end
    end
  end
end
