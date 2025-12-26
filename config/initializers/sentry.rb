# frozen_string_literal: true

# Sentry Error Tracking and Performance Monitoring
# Documentation: docs/sentry-setup.md
# Dashboard: https://sentry.io

Sentry.init do |config|
  # Data Source Name - unique identifier for your Sentry project
  config.dsn = "https://3e61d7879f993c896d21da48232564ef@o4510600781889536.ingest.us.sentry.io/4510600782151680"

  # Enable sending logs to Sentry
  config.enable_logs = true

  # Patch Ruby logger to forward logs
  config.enabled_patches = [:logger]

  # Enable breadcrumbs for better error context
  # HTTP logger captures external API calls
  # Active Support logger captures Rails application activity (jobs, controllers)
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]

  # Limit breadcrumb accumulation to prevent memory growth in long-running processes
  config.max_breadcrumbs = 20  # Reduced from default 100

  # Performance Monitoring: Sample 10% of transactions
  # Reduce to 0.05 (5%) if approaching quota limits
  config.traces_sample_rate = 1.0

  # Profiling: Sample 10% of transactions for performance profiling
  config.profiles_sample_rate = Rails.env.production? ? 0.1 : 0.5

  # Environment name for filtering in Sentry dashboard
  config.environment = Rails.env

  # Release tracking: correlate errors with specific deployments
  # SENTRY_RELEASE should be set during deployment via Kamal
  # See config/deploy.yml for environment variable configuration
  config.release = ENV.fetch("SENTRY_RELEASE", "unknown")

  # Privacy: Don't send PII (Personally Identifiable Information)
  # Sentry SDK 5.x automatically scrubs common PII when this is false
  config.send_default_pii = false

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
    # CRITICAL: Detect Monero wallet addresses and drop event entirely if found
    # Monero addresses start with 4 followed by specific base58 characters
    monero_wallet_pattern = /4[0-9AB][1-9A-HJ-NP-Za-km-z]{93}/

    # Convert event to JSON for comprehensive searching
    event_json = event.to_json
    if event_json.match?(monero_wallet_pattern)
      Rails.logger.error "Sentry event contains Monero wallet address - dropping event for security"
      return nil  # Drop event entirely
    end

    # Filter cloudflare-rails cache initialization errors
    # These are benign - the gem gracefully falls back to hardcoded IPs
    if event.message&.include?("cloudflare-rails: error fetching ip addresses") ||
       event.message&.include?("Could not find table 'solid_cache_entries'")
      return nil  # Drop event - this is expected during initialization
    end

    # Additional scrubbing for database connection strings
    if event.extra[:database_url]
      begin
        uri = URI.parse(event.extra[:database_url])
        uri.password = "[FILTERED]" if uri.password
        uri.user = "[FILTERED]" if uri.user
        event.extra[:database_url] = uri.to_s
      rescue URI::InvalidURIError
        event.extra[:database_url] = "[INVALID_URL_FILTERED]"
      end
    end

    # Filter worker_id if it contains sensitive info
    if event.extra[:worker_id]&.match?(/secret|token|key/)
      event.extra[:worker_id] = "[FILTERED]"
    end

    # Return event to send to Sentry (return nil to drop the event)
    event
  end
end
