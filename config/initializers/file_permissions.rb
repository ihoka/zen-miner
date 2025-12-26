# frozen_string_literal: true

# Set proper file permissions for shared database access
# This ensures files created by Rails have group write permissions
# so the host daemon (xmrig-orchestrator) can access the SQLite database
if Rails.env.production?
  # Set umask to 002 (files: 664, dirs: 775)
  # This ensures group write permissions on all created files
  File.umask(0002)
end
