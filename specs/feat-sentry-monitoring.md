# Feature Specification: Sentry Error Tracking and Performance Monitoring

**Status:** Draft
**Author:** Claude
**Date:** 2025-12-26
**Type:** Feature Enhancement

---

## Overview

Integrate Sentry error tracking and performance monitoring into the Zen Miner application to provide centralized observability across the Rails application, background jobs, and host orchestrator daemons. This enables real-time error detection, performance monitoring, and proactive alerting for production mining operations.

---

## Background/Problem Statement

The Zen Miner application currently lacks centralized error tracking and performance monitoring across its distributed architecture. This creates operational blind spots that make it difficult to detect, diagnose, and resolve issues quickly.

### Current State

**Rails Application:**
- Logs to STDOUT with basic `Rails.logger.info` calls
- No structured error tracking or aggregation
- No performance metrics or trend analysis
- Errors only visible in raw Kamal logs

**Background Jobs (Solid Queue):**
- Job failures logged but not aggregated
- No visibility into job performance trends
- No alerting on repeated failures

**Host Orchestrator Daemons:**
- Each daemon logs independently to `/var/log/xmrig/orchestrator.log`
- No centralized view across multiple mining hosts
- Errors require SSH access to each host to investigate

### Problems This Creates

1. **Delayed Issue Detection**: Operators don't know when errors occur until mining stops or users report issues
2. **Difficult Debugging**: Error context is scattered across multiple log files on different hosts
3. **No Trend Analysis**: Cannot see if error rates are increasing or identify recurring issues
4. **Manual Monitoring**: Must manually check logs on each host to verify health
5. **Performance Blind Spots**: No visibility into slow requests, database queries, or job processing times
6. **Release Risk**: No ability to correlate errors with specific deployments

### Real-World Scenarios

**Scenario 1: Silent Mining Failures**
- XMRig crashes on one of 10 mining hosts
- Orchestrator daemon encounters database connection errors
- Operators don't notice until hashrate drops significantly
- Must SSH to each host and grep logs to find the error

**Scenario 2: Background Job Issues**
- Solid Queue jobs start failing intermittently
- No alerting, failures accumulate in queue
- Problem only discovered during manual investigation
- Root cause unclear without full error context

**Scenario 3: Performance Degradation**
- Database queries slow down gradually
- Action Cable WebSocket connections timeout
- Users experience sluggish interface
- No metrics to identify bottleneck

---

## Goals

- **Centralized Error Tracking**: Aggregate all errors from Rails app, background jobs, and orchestrator daemons in one place
- **Automatic Context Capture**: Include full stack traces, environment data, user context, and request parameters
- **Performance Monitoring**: Track request response times, database query performance, and job execution duration
- **Proactive Alerting**: Get notified immediately when errors occur or thresholds are exceeded
- **Release Tracking**: Correlate errors with specific deployments to quickly identify regressions
- **Environment Segmentation**: Separate development, test, and production errors for clarity
- **Background Job Monitoring**: Track Solid Queue job failures, retries, and performance
- **Distributed Tracing**: Follow requests across Rails → background jobs → orchestrator daemons

---

## Non-Goals

- Custom metrics or business analytics (use dedicated analytics tool instead)
- Real-time dashboards for mining hashrates (XMRig has built-in API for this)
- Log aggregation for all application logs (Sentry focuses on errors and transactions, not general logs)
- Replacing systemd journald for orchestrator daemon logs (Sentry supplements, doesn't replace)
- Monitoring XMRig process itself (use existing health check mechanism)
- Application profiling or code coverage (use Ruby profiling tools instead)

---

## Technical Dependencies

### External Services

| Service | Version | Purpose |
|---------|---------|---------|
| [Sentry SaaS](https://sentry.io) | Latest | Error tracking and performance monitoring platform |

### Ruby Gems

| Gem | Version | Purpose | Documentation |
|-----|---------|---------|---------------|
| `sentry-ruby` | ~> 5.22 | Core Sentry SDK for Ruby | [Docs](https://docs.sentry.io/platforms/ruby/) |
| `sentry-rails` | ~> 5.22 | Rails integration (controllers, ActiveJob, ActionCable) | [Docs](https://docs.sentry.io/platforms/ruby/guides/rails/) |

### Existing Dependencies (No Changes)

- Ruby 3.4.5
- Rails 8.1.1
- Solid Queue (already integrated via ActiveJob)
- SQLite3

### Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `SENTRY_DSN` | Sentry project DSN (Data Source Name) | Yes (production) |
| `SENTRY_ENVIRONMENT` | Environment name (development, test, production) | No (auto-detected) |
| `SENTRY_RELEASE` | Git SHA or version tag for release tracking | No (auto-detected) |

---

## Detailed Design

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Sentry SaaS Platform                    │
│  (Error aggregation, deduplication, alerting, dashboards)    │
└───────────────▲─────────────▲─────────────▲─────────────────┘
                │             │             │
                │ HTTPS       │ HTTPS       │ HTTPS
                │             │             │
┌───────────────┴─────┐   ┌───┴──────────┐  ┌─┴──────────────┐
│  Rails Application  │   │ Background   │  │  Orchestrator  │
│   (Docker)          │   │   Jobs       │  │    Daemons     │
│                     │   │ (Solid Queue)│  │   (Host)       │
│ • Controllers       │   │              │  │                │
│ • Models/Services   │   │ • Job errors │  │ • Ruby script  │
│ • Action Cable      │   │ • Job perf   │  │ • Logs to file │
│ • Middleware        │   │              │  │ • Polls DB     │
└─────────────────────┘   └──────────────┘  └────────────────┘
```

### Integration Points

#### 1. Rails Application Integration

**File:** `config/initializers/sentry.rb`

Sentry will automatically capture:
- **Controller Exceptions**: Unhandled errors in controllers
- **Middleware Errors**: Rack middleware exceptions
- **ActiveRecord Errors**: Database query failures
- **ActionCable Errors**: WebSocket connection/message errors
- **View Rendering Errors**: Template rendering failures

**Configuration:**
```ruby
Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.traces_sample_rate = 0.1  # 10% of requests for performance monitoring
  config.profiles_sample_rate = 0.1  # 10% profiling
  config.environment = Rails.env
  config.release = ENV.fetch('SENTRY_RELEASE', `git rev-parse HEAD`.chomp)

  # Filter sensitive data
  config.send_default_pii = false
  config.sanitize_fields = [
    'password', 'password_confirmation', 'secret', 'api_key',
    'MONERO_WALLET', 'wallet', 'RAILS_MASTER_KEY'
  ]

  # Only enable in production and staging
  config.enabled_environments = %w[production staging]
end
```

#### 2. Background Job Monitoring (Solid Queue)

The `sentry-rails` gem automatically integrates with ActiveJob, which Solid Queue uses. This provides:

- **Job Failure Tracking**: Exceptions during job execution
- **Job Performance**: Execution time trends per job class
- **Queue Depth**: Time jobs spend waiting in queue
- **Retry Monitoring**: Failed jobs and retry attempts

**Automatic Features:**
- Job class name as transaction name
- Job arguments (sanitized) in error context
- Queue name and priority in tags
- Retry attempt number in context

**No additional configuration required** - works automatically through Rails ActiveJob hooks.

**Reference:** [Sentry Queue Monitoring](https://docs.sentry.io/product/insights/backend/queue-monitoring/)

#### 3. Orchestrator Daemon Integration

The orchestrator daemon (`host-daemon/xmrig-orchestrator`) is a standalone Ruby script that runs outside the Rails application. Integration approach:

**Strategy:** Initialize Sentry SDK in orchestrator daemon script

**Implementation Location:** `host-daemon/xmrig-orchestrator` (lines 8-20, after bundler/inline setup)

**Key Considerations:**
- Daemon runs as systemd service with limited network access
- Must handle Sentry initialization failures gracefully
- Should batch events to reduce network overhead
- Different DSN/environment than Rails app (optional)

**Configuration:**
```ruby
# After bundler/inline block
gemfile do
  source "https://rubygems.org"
  gem "sqlite3", "~> 2.4"
  gem "sentry-ruby", "~> 5.22"  # Add Sentry
end

# Initialize Sentry
require "sentry-ruby"

Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']
  config.environment = "orchestrator-#{ENV.fetch('RAILS_ENV', 'production')}"
  config.release = ENV.fetch('SENTRY_RELEASE', 'unknown')
  config.server_name = Socket.gethostname
  config.before_send = ->(event, hint) {
    # Add custom context
    event.tags[:component] = 'orchestrator'
    event.tags[:hostname] = Socket.gethostname
    event
  }
end
```

**Error Capture Points:**
- Database connection failures
- XMRig API timeout/errors
- Systemd command failures
- Health check failures
- Command processing errors

#### 4. Performance Monitoring

**Transactions Tracked:**
- HTTP requests (controller actions)
- Background job execution
- Database queries (via ActiveRecord)
- Action Cable message handling

**Custom Instrumentation Examples:**

**Service Layer:**
```ruby
# app/services/xmrig/command_service.rb
def start_mining(reason: "manual")
  Sentry.with_scope do |scope|
    scope.set_context("command", { action: "start", reason: reason })

    transaction = Sentry.start_transaction(
      name: "xmrig.command.start",
      op: "command.processing"
    )

    begin
      XmrigCommand.transaction do
        cancel_pending_commands
        XmrigCommand.create!(action: "start", reason: reason, status: "pending")
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
```

**Orchestrator Daemon:**
```ruby
# host-daemon/xmrig-orchestrator (in health_check method)
def health_check
  Sentry.with_scope do |scope|
    scope.set_tag("component", "health_check")
    scope.set_tag("hostname", @hostname)

    begin
      # Existing health check logic...
      response = Net::HTTP.get_response(URI(XMRIG_API_URL))
      # ...
    rescue => e
      Sentry.capture_exception(e)
      @logger.error "Health check failed: #{e.message}"
    end
  end
end
```

### Configuration Management

#### Sentry DSN Storage

**Development/Test:**
- Store in `.env.development.local` (gitignored)
- Optional - Sentry disabled by default in non-production

**Production:**
- Store in Rails encrypted credentials: `bin/rails credentials:edit --environment production`
- Or set as environment variable in `config/deploy.yml` (Kamal secrets)

```yaml
# config/deploy.yml
env:
  secret:
    - SENTRY_DSN
```

**Orchestrator Daemons:**
- Pass SENTRY_DSN as environment variable in systemd service file
- Generated during installation: `host-daemon/lib/installer/systemd_installer.rb`

```ini
# /etc/systemd/system/xmrig-orchestrator.service
[Service]
Environment="SENTRY_DSN=https://public@sentry.io/project-id"
Environment="SENTRY_RELEASE=<GIT_SHA>"
```

### Release Tracking

**Deployment Integration:**

1. **Set release in Kamal deployment:**
```yaml
# config/deploy.yml
env:
  SENTRY_RELEASE: <%= `git rev-parse HEAD`.chomp %>
```

2. **Create Sentry release on deployment:**
```bash
# Add to .kamal/hooks/post-deploy
#!/usr/bin/env bash
sentry-cli releases new "$SENTRY_RELEASE"
sentry-cli releases set-commits "$SENTRY_RELEASE" --auto
sentry-cli releases finalize "$SENTRY_RELEASE"
```

3. **Associate errors with releases:**
- Errors automatically tagged with release version
- Can see which deployment introduced new errors
- Compare error rates before/after releases

### Data Privacy and Scrubbing

**Sensitive Fields (Auto-Scrubbed):**
- `MONERO_WALLET` - wallet addresses
- `RAILS_MASTER_KEY` - encryption keys
- `password` - any password fields
- `secret` - secret tokens
- `api_key` - API credentials

**Custom Scrubbing:**
```ruby
# config/initializers/sentry.rb
config.before_send = lambda do |event, hint|
  # Remove worker_id if it contains sensitive info
  if event.extra[:worker_id]&.match?(/secret/)
    event.extra[:worker_id] = '[FILTERED]'
  end

  # Filter database connection strings
  if event.extra[:database_url]
    event.extra[:database_url] = event.extra[:database_url].gsub(/:[^@]+@/, ':[FILTERED]@')
  end

  event
end
```

### Error Grouping and Fingerprinting

**Default Grouping:**
- Stack trace
- Exception type
- Exception message

**Custom Fingerprinting for Known Issues:**
```ruby
# app/controllers/application_controller.rb
rescue_from ActiveRecord::RecordNotFound do |exception|
  Sentry.with_scope do |scope|
    scope.set_fingerprint(['record-not-found', params[:controller], params[:action]])
    Sentry.capture_exception(exception)
  end

  render file: "#{Rails.root}/public/404.html", status: :not_found
end
```

---

## User Experience

### For Operators/DevOps

**Before Sentry:**
1. Check Kamal logs manually: `kamal app logs`
2. SSH to each host to check orchestrator logs: `ssh deploy@mini-1 'sudo journalctl -u xmrig-orchestrator -n 100'`
3. Grep logs for errors manually
4. No visibility into trends or patterns
5. Reactive - only investigate after issues reported

**After Sentry:**
1. Receive email/Slack alert when errors occur
2. Open Sentry dashboard to see error details:
   - Full stack trace
   - Request parameters and headers
   - User context (hostname, worker_id)
   - Breadcrumbs showing events leading to error
   - Number of occurrences and affected users
3. Filter by release to see if recent deployment caused issue
4. View performance trends to identify degradation
5. Proactive - alerted before users notice issues

### For Developers

**Error Investigation Workflow:**
1. Get Sentry notification: "New error in production: `SQLite3::BusyException` on `mini-1`"
2. Click link to Sentry issue page
3. See error occurred 15 times in last hour
4. View stack trace showing error in `xmrig-orchestrator` line 127
5. See breadcrumbs: database lock timeout during command polling
6. Check "Similar Issues" to see if this happened before
7. View affected releases - started after deployment `abc123`
8. Click "Resolve in Next Release" to track fix

**Performance Monitoring Workflow:**
1. Open Sentry Performance dashboard
2. See `/health` endpoint is slow (p95: 2.5s)
3. Click transaction to see breakdown:
   - Database query: 2.2s (slow!)
   - Rendering: 0.3s
4. View query span details - missing index on `xmrig_processes.last_health_check_at`
5. Add index, deploy, verify performance improvement in next release

---

## Testing Strategy

### Unit Tests

**Test Sentry Configuration:**

```ruby
# test/initializers/sentry_test.rb
require "test_helper"

class SentryConfigurationTest < ActiveSupport::TestCase
  test "sentry dsn is configured in production" do
    assert_not_nil ENV['SENTRY_DSN'] if Rails.env.production?
  end

  test "sentry filters sensitive fields" do
    config = Sentry.configuration
    assert_includes config.sanitize_fields, 'MONERO_WALLET'
    assert_includes config.sanitize_fields, 'password'
  end

  test "sentry release is set" do
    config = Sentry.configuration
    assert_not_nil config.release
  end
end
```

**Purpose:** Verify Sentry is configured correctly and sensitive data is filtered.

**Test Exception Capture:**

```ruby
# test/services/xmrig/command_service_test.rb
class CommandServiceTest < ActiveSupport::TestCase
  test "captures exception to Sentry on failure" do
    # Mock Sentry to verify it's called
    Sentry.expects(:capture_exception).once

    # Simulate database failure
    XmrigCommand.stubs(:transaction).raises(ActiveRecord::StatementInvalid)

    assert_raises(ActiveRecord::StatementInvalid) do
      Xmrig::CommandService.start_mining
    end
  end
end
```

**Purpose:** Verify exceptions are properly captured and sent to Sentry. Tests can fail if exception handling is broken.

### Integration Tests

**Test Background Job Error Tracking:**

```ruby
# test/jobs/example_job_test.rb
class ExampleJobTest < ActiveJob::TestCase
  test "job failures are sent to Sentry" do
    Sentry.expects(:capture_exception).once

    # Create job that will fail
    job = ExampleJob.new
    job.stubs(:perform).raises(StandardError, "Job failed")

    assert_raises(StandardError) do
      job.perform_now
    end
  end
end
```

**Purpose:** Verify ActiveJob integration properly captures job failures. Can fail if Sentry hooks are not installed correctly.

**Test Orchestrator Daemon Sentry Integration:**

```ruby
# test/orchestrator_daemon_sentry_test.rb
require 'minitest/autorun'
require_relative '../host-daemon/xmrig-orchestrator'

class OrchestratorDaemonSentryTest < Minitest::Test
  def test_sentry_captures_database_errors
    # Mock Sentry
    Sentry.expects(:capture_exception).with(instance_of(SQLite3::Exception))

    # Mock database to raise error
    orchestrator = XmrigOrchestrator.new
    orchestrator.instance_variable_get(:@db).stubs(:execute).raises(SQLite3::BusyException)

    # Trigger error condition
    assert_raises(SQLite3::BusyException) do
      orchestrator.send(:poll_commands)
    end
  end
end
```

**Purpose:** Verify orchestrator daemon properly initializes Sentry and captures exceptions. Tests actual integration, can fail if Sentry is not properly configured in daemon.

### Manual Testing Checklist

**Development Environment:**
- [ ] Add test Sentry DSN to `.env.development.local`
- [ ] Trigger controller error, verify appears in Sentry
- [ ] Trigger background job error, verify appears in Sentry
- [ ] Check sensitive data is scrubbed (wallet address, passwords)
- [ ] Verify breadcrumbs include relevant context

**Production Environment:**
- [ ] Deploy with Sentry DSN configured
- [ ] Trigger test error via Rails console: `raise "Sentry test error"`
- [ ] Verify error appears in Sentry with correct release tag
- [ ] Check performance transactions are recorded
- [ ] Verify orchestrator daemon errors appear in Sentry
- [ ] Test alerting rules trigger notifications

### Mocking Strategies

**Mock Sentry in Tests:**

```ruby
# test/test_helper.rb
class ActiveSupport::TestCase
  setup do
    # Disable Sentry in tests by default
    Sentry.configuration.enabled_environments = []
  end

  # Helper to test Sentry integration
  def with_sentry_enabled
    original_envs = Sentry.configuration.enabled_environments
    Sentry.configuration.enabled_environments = ['test']
    yield
  ensure
    Sentry.configuration.enabled_environments = original_envs
  end
end
```

**Mock External API Calls:**
```ruby
# Don't actually send events to Sentry during tests
# Use mocha/minitest mocking to verify Sentry.capture_exception is called
```

### Edge Case Testing

**Test Cases:**
1. **Sentry DSN Missing**: Verify app starts without errors when SENTRY_DSN is not set
2. **Sentry Service Down**: Mock network failure, verify app continues working
3. **Rate Limiting**: Simulate high error volume, verify Sentry rate limiting doesn't crash app
4. **Large Error Payloads**: Test with very large stack traces or request bodies
5. **Concurrent Errors**: Multiple threads/processes reporting errors simultaneously

**Expected Behavior:**
- Application should never crash due to Sentry issues
- Errors should be logged locally if Sentry is unavailable
- Rate limiting should prevent overwhelming Sentry service

---

## Performance Considerations

### Impact on Application Performance

**Overhead Estimates:**
- **Error Capture**: ~5-10ms per error (only when error occurs)
- **Performance Tracing**: ~1-2ms per traced request (10% sample rate)
- **Breadcrumbs**: Negligible (<1ms)
- **Network**: Async, non-blocking HTTP requests to Sentry

**Sampling Strategy:**
```ruby
# Reduce performance monitoring overhead
config.traces_sample_rate = 0.1  # Only 10% of transactions

# Sample more aggressively in development
config.traces_sample_rate = Rails.env.production? ? 0.1 : 0.5
```

### Network and Memory

**Batching:**
- Sentry SDK batches events to reduce network overhead
- Events sent asynchronously in background thread
- Default batch size: 100 events or 1 second (whichever comes first)

**Memory Usage:**
- SDK maintains in-memory queue of ~100 events max
- Estimated memory overhead: <10MB

**Network Traffic:**
- Average event size: ~5-10KB (compressed)
- At 100 errors/day: ~1MB/day
- Performance transactions: ~2-3KB each
- Estimated monthly traffic: <100MB (well within free tier)

### Mitigation Strategies

**1. Rate Limiting:**
```ruby
# Prevent error storms from overwhelming Sentry
config.before_send = lambda do |event, hint|
  # Skip if too many similar events recently
  return nil if event_rate_limited?(event)
  event
end
```

**2. Sampling for High-Volume Endpoints:**
```ruby
# Don't trace health check endpoint
config.traces_sampler = lambda do |sampling_context|
  transaction_context = sampling_context[:transaction_context]
  transaction_name = transaction_context[:name]

  case transaction_name
  when /health|up/
    0.0  # Never sample health checks
  when /api/
    0.3  # 30% of API requests
  else
    0.1  # 10% of other requests
  end
end
```

**3. Async Processing:**
- All Sentry events sent asynchronously
- No blocking on main request thread
- Background thread handles retries

**4. Graceful Degradation:**
```ruby
# If Sentry fails, log locally and continue
config.transport.on_error = lambda do |error|
  Rails.logger.error "Sentry error: #{error.message}"
end
```

### Database Impact

**Orchestrator Daemon:**
- Daemon already polls database every 10 seconds
- Sentry adds negligible overhead to existing queries
- No additional database load from Sentry integration

**Rails Application:**
- Sentry captures database query spans for performance monitoring
- Uses ActiveSupport::Notifications (already instrumented)
- No additional database queries

---

## Security Considerations

### Data Privacy

**Sensitive Data Handling:**

1. **Wallet Addresses**: Must NEVER be sent to Sentry
   - Scrubbed via `sanitize_fields` configuration
   - Additional `before_send` hook validation

2. **Master Key**: Rails master key must not appear in errors
   - Filtered automatically by Sentry
   - Verify in test suite

3. **Database Connection Strings**: May contain credentials
   - Scrub from error messages
   - Filter environment variables

**Compliance:**
- No PII (Personally Identifiable Information) sent to Sentry
- Mining rig hostnames are considered operational data (not PII)
- Worker IDs are anonymous identifiers (not PII)

### Sentry DSN Security

**DSN is Public-ish:**
- DSN contains project ID (public)
- DSN contains public key (safe to expose)
- No secret key in DSN
- Rate limiting prevents abuse

**Best Practices:**
- Store DSN in environment variables
- Use separate projects for dev/staging/production
- Rotate DSN if compromised (regenerate in Sentry UI)

**Access Control:**
- Only production servers have production DSN
- Development DSN separate (or disabled)
- Orchestrator daemons use same DSN as Rails app (or separate)

### Network Security

**TLS Encryption:**
- All Sentry communication over HTTPS
- Events encrypted in transit
- Certificates validated by SDK

**Firewall Rules:**
- Orchestrator daemons need outbound HTTPS access to `sentry.io`
- No inbound connections required
- Can whitelist Sentry IPs if needed

### Rate Limiting and Abuse Prevention

**Sentry Free Tier Limits:**
- 5,000 errors per month
- Resets monthly
- Overage behavior: Events dropped (not charged)

**Application-Side Rate Limiting:**
```ruby
# Prevent single error from consuming entire quota
config.before_send = lambda do |event, hint|
  # Track error counts per fingerprint
  fingerprint = event.fingerprint.join(':')
  count = increment_error_count(fingerprint)

  # Drop if exceeded limit (e.g., 100/hour)
  return nil if count > 100

  event
end
```

**DDoS Protection:**
- Sentry SDK has built-in client-side sampling
- Transport layer retries with exponential backoff
- Circuit breaker pattern prevents overwhelming Sentry API

---

## Documentation

### Files to Create/Update

| File | Purpose |
|------|---------|
| `docs/sentry-setup.md` | **New** - Sentry setup guide for operators |
| `README.md` | **Update** - Add Sentry to tech stack section |
| `config/deploy.yml` | **Update** - Document SENTRY_DSN secret |
| `.env.example` | **Update** - Add SENTRY_DSN example |
| `CLAUDE.md` | **Update** - Add Sentry to monitoring section |

### Sentry Setup Guide Contents

```markdown
# Sentry Error Tracking Setup

## Creating Sentry Account

1. Sign up at https://sentry.io (free tier)
2. Create new project: "zen-miner-production"
3. Select platform: "Ruby on Rails"
4. Copy DSN from project settings

## Configuration

### Rails Application

1. Add SENTRY_DSN to production credentials:
   ```bash
   bin/rails credentials:edit --environment production
   ```

2. Or set in Kamal deploy.yml:
   ```yaml
   env:
     secret:
       - SENTRY_DSN
   ```

3. Deploy: `kamal deploy`

### Orchestrator Daemons

1. Set SENTRY_DSN in host environment
2. Update systemd service file to include SENTRY_DSN
3. Restart daemon: `sudo systemctl restart xmrig-orchestrator`

## Verification

1. Trigger test error in Rails console:
   ```ruby
   raise "Sentry test error"
   ```

2. Check error appears in Sentry dashboard
3. Verify release tag is correct
4. Test alerting notification

## Alerting Setup

1. Open Sentry project settings
2. Go to Alerts → New Alert Rule
3. Configure:
   - Condition: "Errors exceed 10 in 1 hour"
   - Action: Email/Slack notification
4. Test alert

## Monitoring Best Practices

- Review errors weekly
- Set up alerts for critical error types
- Tag releases with git SHA
- Use "Resolve in Next Release" for fixed bugs
- Archive or ignore known issues
```

### Code Comments

Add inline documentation:

```ruby
# config/initializers/sentry.rb
# Sentry error tracking and performance monitoring
# Documentation: docs/sentry-setup.md
# Dashboard: https://sentry.io/organizations/your-org/projects/zen-miner/
Sentry.init do |config|
  # ...
end
```

---

## Implementation Phases

### Phase 1: Core Rails Integration (MVP)

**Goal:** Basic error tracking for Rails application

**Tasks:**
1. Add `sentry-ruby` and `sentry-rails` to Gemfile
2. Create `config/initializers/sentry.rb`
3. Configure sensitive field filtering
4. Set up environment variable handling
5. Test in development environment
6. Deploy to production
7. Verify errors are captured

**Validation:**
- Manually trigger test error
- Verify error appears in Sentry with full context
- Confirm sensitive data is scrubbed

### Phase 2: Background Jobs & Performance Monitoring

**Goal:** Track Solid Queue jobs and application performance

**Tasks:**
1. Enable performance tracing in Sentry config
2. Add custom instrumentation to `Xmrig::CommandService`
3. Configure transaction sampling rates
4. Test background job error capture
5. Deploy and monitor

**Validation:**
- Trigger job failure, verify captured in Sentry
- Check performance transactions appear
- Verify queue metrics are tracked

### Phase 3: Orchestrator Daemon Integration

**Goal:** Centralized error tracking for host daemons

**Tasks:**
1. Add sentry-ruby to orchestrator bundler/inline gemfile
2. Initialize Sentry in orchestrator script
3. Add error capture to critical sections:
   - Database operations
   - XMRig API calls
   - Systemd commands
4. Update systemd service to include SENTRY_DSN
5. Update installer to configure Sentry
6. Deploy orchestrator updates to hosts

**Validation:**
- Trigger orchestrator error (e.g., stop database)
- Verify error appears in Sentry tagged with hostname
- Confirm daemon continues running after Sentry error

### Phase 4: Release Tracking & Alerts

**Goal:** Correlate errors with deployments and set up alerting

**Tasks:**
1. Add Kamal post-deploy hook for release creation
2. Configure Sentry release tracking
3. Set up alert rules:
   - New error type detected
   - Error rate exceeds threshold
   - Specific error occurs
4. Configure notification channels (email, Slack)
5. Document alerting playbook

**Validation:**
- Deploy new release, verify appears in Sentry
- Check errors are tagged with release
- Test alert notifications work

### Phase 5: Optimization & Documentation

**Goal:** Fine-tune configuration and complete documentation

**Tasks:**
1. Adjust sampling rates based on actual traffic
2. Add custom fingerprinting for known issues
3. Configure error grouping rules
4. Write comprehensive setup guide
5. Add monitoring best practices to docs
6. Create runbook for common errors

**Validation:**
- Review Sentry quota usage
- Verify error grouping is intuitive
- Test setup guide with fresh Sentry account

---

## Open Questions

1. **Sentry Account Ownership**: Should we use organization account or personal account for production?
   - **Impact**: Billing, access control, team collaboration
   - **Decision needed by**: DevOps lead

2. **Separate Projects vs. Single Project**: Use one Sentry project for all environments or separate?
   - **Option A**: Single project with environment tags (simpler, shared quota)
   - **Option B**: Separate projects per environment (cleaner separation, separate quotas)
   - **Recommendation**: Separate projects for production vs. development/staging

3. **Orchestrator Daemon DSN**: Same DSN as Rails app or separate Sentry project?
   - **Option A**: Same project (simpler, unified view)
   - **Option B**: Separate project (clearer separation, different alerting rules)
   - **Recommendation**: Same project initially, split if volume requires it

4. **Performance Monitoring Quota**: Free tier includes 10K performance units/month. Is this sufficient?
   - **Analysis needed**: Estimate transaction volume per month
   - **Mitigation**: Adjust sample rate if approaching limit

5. **Alert Fatigue**: How to prevent alert fatigue from non-critical errors?
   - **Strategy needed**: Define critical vs. non-critical errors
   - **Action**: Start with conservative alerting, tune based on experience

6. **Historical Data Retention**: Free tier retains 90 days of data. Is this sufficient?
   - **Impact**: Can't analyze trends beyond 90 days
   - **Mitigation**: Export critical data if needed, or upgrade to paid tier

7. **Source Maps**: For JavaScript errors (Stimulus controllers), do we need source maps?
   - **Impact**: Stack traces show minified code without source maps
   - **Decision**: Yes if JavaScript errors are common, can add in later phase

---

## References

### Sentry Documentation

- [Sentry Ruby SDK](https://docs.sentry.io/platforms/ruby/)
- [Sentry Rails Integration](https://docs.sentry.io/platforms/ruby/guides/rails/)
- [Sentry Queue Monitoring](https://docs.sentry.io/product/insights/backend/queue-monitoring/)
- [Sentry Ruby GitHub Repository](https://github.com/getsentry/sentry-ruby)

### Related Specifications

- `specs/archive/feat-xmrig-daemon-orchestration.md` - Orchestrator daemon architecture
- `specs/archive/feat-kamal-deployment-setup.md` - Deployment infrastructure
- `specs/feat-simplify-installer-updater.md` - Installer architecture

### External Resources

- [Rails ActiveJob Documentation](https://guides.rubyonrails.org/active_job_basics.html)
- [Solid Queue GitHub](https://github.com/rails/solid_queue)
- [Sentry Best Practices](https://docs.sentry.io/product/best-practices/)
- [AppSignal Solid Queue Monitoring](https://blog.appsignal.com/2025/06/18/a-deep-dive-into-solid-queue-for-ruby-on-rails.html) - Alternative monitoring approach

### Issue Tracking

- GitHub Issues: Tag with `monitoring`, `sentry`, `ops`
- Related issues: (to be added as implementation progresses)

---

## Revision History

| Date | Author | Changes |
|------|--------|---------|
| 2025-12-26 | Claude | Initial draft |

---

## Appendix: Sentry Free Tier Limits

| Resource | Free Tier Limit | Notes |
|----------|----------------|-------|
| Errors | 5,000/month | Resets monthly, overage dropped |
| Performance Units | 10,000/month | 1 transaction = 1 unit |
| Attachments | 1GB storage | Screenshots, files |
| Team Members | Unlimited | Invite anyone |
| Projects | 1 | Can upgrade for more |
| Data Retention | 90 days | Historical data deleted after 90 days |
| Alerts | 1,000/month | Email/webhook notifications |

**Estimated Usage for Zen Miner:**
- Errors: ~100-500/month (healthy production app)
- Performance units: ~3,000/month (at 10% sampling, 1,000 requests/day)
- Well within free tier limits

**Upgrade Triggers:**
- Exceeding 5K errors/month consistently
- Need more than 90 days data retention
- Require multiple projects (dev/staging/prod separation)
- Need advanced features (SSO, custom retention)
