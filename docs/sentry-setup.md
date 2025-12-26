# Sentry Error Tracking Setup

## Quick Start

### 1. Create Sentry Account

1. Sign up at [https://sentry.io](https://sentry.io) (free tier includes 5,000 errors/month)
2. Create new project → Select "Rails"
3. Copy the DSN from project settings (looks like: `https://PUBLIC_KEY@o0.ingest.sentry.io/PROJECT_ID`)

### 2. Configure Rails Application

**Option A: Using Kamal Deployment (Recommended for Production)**

Add to your deployment secrets:

```yaml
# config/deploy.yml
env:
  clear:
    # Set release tracking (correlates errors with deployments)
    SENTRY_RELEASE: <%= `git rev-parse HEAD`.chomp %>
  secret:
    # Add SENTRY_DSN to your secrets
    - SENTRY_DSN
```

Then set the secret on your deployment host:

```bash
# On your local machine
kamal env set SENTRY_DSN=https://YOUR_PUBLIC_KEY@o0.ingest.sentry.io/PROJECT_ID
```

**Option B: Using Rails Credentials (Alternative)**

```bash
bin/rails credentials:edit --environment production
# Add: sentry_dsn: "https://YOUR_PUBLIC_KEY@o0.ingest.sentry.io/PROJECT_ID"
```

Then update `config/initializers/sentry.rb`:

```ruby
config.dsn = Rails.application.credentials.dig(:sentry_dsn) || ENV["SENTRY_DSN"]
```

### 3. Deploy

```bash
# Deploy Rails application
bin/kamal deploy

# Verify environment variable is set
bin/kamal env | grep SENTRY
```

### 4. Verify Installation

Test that Sentry is receiving errors:

```bash
# SSH to server and trigger test error
bin/kamal app exec 'bin/rails runner "raise '\''Sentry test error'\''"'

# Or via Rails console
bin/kamal app exec --interactive 'bin/rails console'
> raise "Sentry test error - this is expected"
```

Check https://sentry.io to confirm the error was received (usually appears within 1-2 minutes).

---

## Configuration Overview

The Sentry initializer (`config/initializers/sentry.rb`) is pre-configured with production-ready settings:

### Security & Privacy
- ✅ Automatic sensitive field filtering (wallet addresses, passwords, secrets)
- ✅ Monero wallet address detection (events dropped if wallet found)
- ✅ No PII (Personally Identifiable Information) sent by default
- ✅ Database connection string sanitization

### Performance Optimization
- ✅ 10% transaction sampling (only 10% of requests traced)
- ✅ Health endpoint exclusion (0% sampling to save quota)
- ✅ Reduced breadcrumb logging (20 max instead of 100)
- ✅ Async event sending (non-blocking)

### Error Tracking
- ✅ Automatic Rails controller/job integration
- ✅ Background job failures (Solid Queue via ActiveJob)
- ✅ Custom command tracking (mining start/stop/restart)
- ✅ Graceful fallback if Sentry unavailable

---

## Monitoring Best Practices

### 1. Set Up Alerts

Configure alerts in Sentry dashboard for proactive monitoring:

1. Go to your project → **Alerts** → **Create Alert Rule**
2. Recommended alerts:
   - **New Error Type**: Alert when a new error signature appears
   - **High Error Rate**: Alert when errors exceed 10 in 5 minutes
   - **Mining Command Failures**: Filter by `transaction:"xmrig.command.*"` with any error
   - **Background Job Failures**: Filter by tag `job_class:*` with level:error

### 2. Use Release Tracking

Errors are automatically tagged with git SHA when `SENTRY_RELEASE` is set:

- View errors by release to identify regressions
- Use "Resolve in Next Release" to track fixes
- Compare error rates before/after deployments

### 3. Review Weekly

- Check recurring issues (same error multiple times)
- Archive or ignore known/expected errors
- Update sensitive field filtering if new patterns emerge

### 4. Manage Quota

**Free Tier Limits:**
- 5,000 errors/month
- 10,000 performance units/month
- 90 days data retention

**If approaching limits:**
1. Reduce sampling rate in `config/initializers/sentry.rb`:
   ```ruby
   config.traces_sample_rate = Rails.env.production? ? 0.05 : 0.5  # Reduce to 5%
   ```
2. Filter out noisy errors that aren't actionable
3. Consider upgrading to paid tier if needed

---

## Troubleshooting

### Sentry Not Receiving Errors

**Check 1: Verify DSN is set**
```bash
# Check environment variable
bin/kamal env | grep SENTRY

# Or via Rails console
bin/kamal app exec --interactive 'bin/rails console'
> ENV["SENTRY_DSN"]
# Should output your DSN
```

**Check 2: Verify Rails environment**
```bash
# Sentry only enabled in production/staging
bin/kamal app exec 'bin/rails runner "puts Rails.env"'
# Should output: production
```

**Check 3: Check application logs**
```bash
# Look for Sentry initialization messages
bin/kamal logs | grep -i sentry

# Look for errors in Sentry itself
bin/kamal logs | grep -i "Sentry error"
```

**Check 4: Trigger test error**
```bash
# This should appear in Sentry within 1-2 minutes
bin/kamal app exec 'bin/rails runner "raise '\''Test error for Sentry'\''"'
```

### Development Setup (Optional)

To test Sentry integration locally:

1. Create a separate Sentry project for development
2. Add to `.env.development.local` (gitignored):
   ```
   SENTRY_DSN=https://YOUR_DEV_DSN@o0.ingest.sentry.io/DEV_PROJECT_ID
   ```
3. Temporarily enable in development:
   ```ruby
   # config/initializers/sentry.rb
   config.enabled_environments = %w[production staging development]
   ```
4. Start Rails server and trigger test error in console

**Remember to remove development from enabled_environments before committing!**

---

## Advanced: Orchestrator Daemon Setup (Phase 2)

*Note: This feature is planned for Phase 2 and not yet implemented.*

To enable Sentry for host orchestrator daemons:

1. Set `SENTRY_DSN` when installing daemon:
   ```bash
   export SENTRY_DSN="your-dsn-here"
   sudo ./host-daemon/install.sh
   ```

2. Verify in systemd service:
   ```bash
   sudo systemctl cat xmrig-orchestrator | grep SENTRY
   ```

3. Check daemon logs for Sentry events:
   ```bash
   sudo journalctl -u xmrig-orchestrator | grep -i sentry
   ```

---

## Reference

- **Sentry Dashboard**: https://sentry.io
- **Sentry Documentation**: https://docs.sentry.io/platforms/ruby/guides/rails/
- **Feature Specification**: `specs/feat-sentry-monitoring.md`
- **Initializer Configuration**: `config/initializers/sentry.rb`

---

## Support

If you encounter issues:

1. Check this troubleshooting guide
2. Review Sentry logs: `bin/kamal logs | grep -i sentry`
3. Consult feature specification: `specs/feat-sentry-monitoring.md`
4. Check Sentry status: https://status.sentry.io
