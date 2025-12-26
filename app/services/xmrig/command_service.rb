module Xmrig
  class CommandService
    class << self
      def start_mining(reason: "manual")
        Sentry.with_scope do |scope|
          scope.set_context("command", { action: "start", reason: reason })
          scope.set_tag("command_type", "start")

          transaction = Sentry.start_transaction(
            name: "xmrig.command.start",
            op: "command.processing"
          )

          begin
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
          rescue => e
            Sentry.capture_exception(e)
            raise
          ensure
            transaction&.finish
          end
        end
      end

      def stop_mining(reason: "manual")
        Sentry.with_scope do |scope|
          scope.set_context("command", { action: "stop", reason: reason })
          scope.set_tag("command_type", "stop")

          transaction = Sentry.start_transaction(
            name: "xmrig.command.stop",
            op: "command.processing"
          )

          begin
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
          rescue => e
            Sentry.capture_exception(e)
            raise
          ensure
            transaction&.finish
          end
        end
      end

      def restart_mining(reason: "health_check_failed")
        Sentry.with_scope do |scope|
          scope.set_context("command", { action: "restart", reason: reason })
          scope.set_tag("command_type", "restart")
          scope.set_tag("restart_reason", reason)

          transaction = Sentry.start_transaction(
            name: "xmrig.command.restart",
            op: "command.processing"
          )

          begin
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
          rescue => e
            Sentry.capture_exception(e)
            raise
          ensure
            transaction&.finish
          end
        end
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
