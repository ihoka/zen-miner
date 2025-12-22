module Xmrig
  class CommandService
    class << self
      def start_mining(hostname, reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(hostname)

          XmrigCommand.create!(
            hostname: hostname,
            action: "start",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued start command for #{hostname}"
      end

      def stop_mining(hostname, reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(hostname)

          XmrigCommand.create!(
            hostname: hostname,
            action: "stop",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued stop command for #{hostname}"
      end

      def restart_mining(hostname, reason: "health_check_failed")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(hostname)

          XmrigCommand.create!(
            hostname: hostname,
            action: "restart",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued restart command for #{hostname}: #{reason}"
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
