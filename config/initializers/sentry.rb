# frozen_string_literal: true

# Sentry Error Tracking and Performance Monitoring
# Documentation: docs/sentry-setup.md
# Dashboard: https://sentry.io

Sentry.init do |config|
  # Data Source Name - unique identifier for your Sentry project
  config.dsn = ENV["SENTRY_DSN"]

  # Enable breadcrumbs for better error context
  # Active Support logger captures Rails logs, HTTP logger captures HTTP requests
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

  # Performance Monitoring: Sample 10% of transactions
  # Reduce to 0.05 (5%) if approaching quota limits
  config.traces_sample_rate = Rails.env.production? ? 0.1 : 0.5

  # Profiling: Sample 10% of transactions for performance profiling
  config.profiles_sample_rate = Rails.env.production? ? 0.1 : 0.5

  # Environment name for filtering in Sentry dashboard
  config.environment = Rails.env

  # Release tracking: correlate errors with specific deployments
  # Git SHA from environment variable or fallback to git command
  config.release = ENV.fetch("SENTRY_RELEASE") do
    begin
      `git rev-parse HEAD`.chomp
    rescue
      "unknown"
    end
  end

  # Privacy: Don't send PII (Personally Identifiable Information)
  config.send_default_pii = false

  # Sensitive field scrubbing: automatically filter these fields from error payloads
  config.sanitize_fields = [
    # Authentication & Secrets
    "password",
    "password_confirmation",
    "secret",
    "api_key",
    "access_token",
    "auth_token",

    # Mining-specific sensitive data
    "MONERO_WALLET",
    "wallet",
    "wallet_address",

    # Rails credentials
    "RAILS_MASTER_KEY",
    "SECRET_KEY_BASE",

    # Database credentials
    "database_url",
    "DATABASE_URL"
  ]

  # Only enable Sentry in production and staging environments
  # Development and test environments won't send events to save quota
  config.enabled_environments = %w[production staging]

  # Custom sampling for specific transaction types
  config.traces_sampler = lambda do |sampling_context|
    transaction_context = sampling_context[:transaction_context]
    transaction_name = transaction_context[:name]

    case transaction_name
    when /health|up/
      # Never sample health check endpoints to save quota
      0.0
    when /api/
      # Sample 30% of API requests for better visibility
      0.3
    else
      # Default: 10% of other requests
      Rails.env.production? ? 0.1 : 0.5
    end
  end

  # Custom before_send hook for additional data scrubbing
  config.before_send = lambda do |event, hint|
    # Additional scrubbing for database connection strings
    if event.extra[:database_url]
      event.extra[:database_url] = event.extra[:database_url].gsub(/:[^@]+@/, ":[FILTERED]@")
    end

    # Filter worker_id if it contains sensitive info
    if event.extra[:worker_id]&.match?(/secret|token|key/)
      event.extra[:worker_id] = "[FILTERED]"
    end

    # Return event to send to Sentry (return nil to drop the event)
    event
  end

  # Error handling for Sentry itself
  # If Sentry fails, log locally and continue application operation
  config.transport.on_error = lambda do |error|
    Rails.logger.error "Sentry error: #{error.message}"
  end
end
