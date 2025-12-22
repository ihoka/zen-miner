module Xmrig
  class CommandService
    class << self
      def start_mining(reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(worker_id)

          XmrigCommand.create!(
            hostname: worker_id,
            action: "start",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued start command for #{worker_id}"
      end

      def stop_mining(reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(worker_id)

          XmrigCommand.create!(
            hostname: worker_id,
            action: "stop",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued stop command for #{worker_id}"
      end

      def restart_mining(reason: "health_check_failed")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands(worker_id)

          XmrigCommand.create!(
            hostname: worker_id,
            action: "restart",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued restart command for #{worker_id}: #{reason}"
      end

      private

      def worker_id
        ENV.fetch('WORKER_ID')
      end

      def cancel_pending_commands(hostname)
        XmrigCommand.for_host(hostname).pending.update_all(
          status: "failed",
          error_message: "Superseded by new command"
        )
      end
    end
  end
end
