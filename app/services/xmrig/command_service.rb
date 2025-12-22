module Xmrig
  class CommandService
    class << self
      def start_mining(reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands

          XmrigCommand.create!(
            action: "start",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued start command"
      end

      def stop_mining(reason: "manual")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands

          XmrigCommand.create!(
            action: "stop",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued stop command"
      end

      def restart_mining(reason: "health_check_failed")
        # Atomically cancel pending commands and create new command to prevent race conditions
        XmrigCommand.transaction do
          cancel_pending_commands

          XmrigCommand.create!(
            action: "restart",
            reason: reason,
            status: "pending"
          )
        end

        Rails.logger.info "Issued restart command: #{reason}"
      end

      private

      def cancel_pending_commands
        XmrigCommand.pending.update_all(
          status: "failed",
          error_message: "Superseded by new command"
        )
      end
    end
  end
end
