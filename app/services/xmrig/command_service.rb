module Xmrig
  class CommandService
    class << self
      def start_mining(hostname, reason: "manual")
        # Cancel any pending stop/restart commands
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: "start",
          reason: reason,
          status: "pending"
        )

        Rails.logger.info "Issued start command for #{hostname}"
      end

      def stop_mining(hostname, reason: "manual")
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: "stop",
          reason: reason,
          status: "pending"
        )

        Rails.logger.info "Issued stop command for #{hostname}"
      end

      def restart_mining(hostname, reason: "health_check_failed")
        cancel_pending_commands(hostname)

        XmrigCommand.create!(
          hostname: hostname,
          action: "restart",
          reason: reason,
          status: "pending"
        )

        Rails.logger.info "Issued restart command for #{hostname}: #{reason}"
      end

      def start_all
        Rails.application.config.xmrig_hosts.each do |hostname|
          start_mining(hostname, reason: "start_all")
        end
      end

      def stop_all
        Rails.application.config.xmrig_hosts.each do |hostname|
          stop_mining(hostname, reason: "stop_all")
        end
      end

      private

      def cancel_pending_commands(hostname)
        XmrigCommand.for_host(hostname).pending.update_all(
          status: "failed",
          error_message: "Superseded by new command"
        )
      end
    end
  end
end
