module Xmrig
  class CommandService
    class << self
      def start_mining(reason: "manual")
        execute_command(action: "start", reason: reason)
      end

      def stop_mining(reason: "manual")
        execute_command(action: "stop", reason: reason)
      end

      def restart_mining(reason: "health_check_failed")
        execute_command(action: "restart", reason: reason) do |scope|
          # Add restart-specific tag for better filtering in Sentry
          scope.set_tag("restart_reason", reason)
        end
      end

      private

      def execute_command(action:, reason:)
        # Validate and sanitize reason parameter to prevent injection
        validated_reason = sanitize_reason(reason)

        Sentry.with_scope do |scope|
          scope.set_context("command", { action: action, reason: validated_reason })
          scope.set_tag("command_type", action)

          # Allow additional scope configuration (e.g., restart_reason tag)
          yield scope if block_given?

          transaction = Sentry.start_transaction(
            name: "xmrig.command.#{action}",
            op: "command.processing"
          )

          begin
            # Atomically cancel pending commands and create new command to prevent race conditions
            XmrigCommand.transaction do
              cancel_pending_commands

              XmrigCommand.create!(
                action: action,
                reason: validated_reason,
                status: "pending"
              )
            end

            Rails.logger.info "Issued #{action} command#{log_reason(validated_reason)}"
          rescue => e
            Sentry.capture_exception(e)
            raise
          ensure
            transaction&.finish
          end
        end
      end

      def cancel_pending_commands
        XmrigCommand.pending.update_all(
          status: "failed",
          error_message: "Superseded by new command"
        )
      end

      def sanitize_reason(reason)
        # Validate and sanitize reason parameter
        # - Limit length to prevent excessive data in Sentry
        # - Remove potentially dangerous characters
        reason.to_s
              .slice(0, 100)
              .gsub(/[^a-zA-Z0-9_\-\s]/, "")
              .strip
              .presence || "unknown"
      end

      def log_reason(reason)
        # Only append reason to log message if it's not the default
        reason == "manual" ? "" : ": #{reason}"
      end
    end
  end
end
