class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Sentry error context enrichment
  before_action :set_sentry_context

  # Error boundary for common exceptions
  rescue_from ActiveRecord::RecordNotFound do |exception|
    Sentry.with_scope do |scope|
      scope.set_fingerprint(["record-not-found", params[:controller], params[:action]])
      scope.set_context("request", {
        controller: params[:controller],
        action: params[:action],
        id: params[:id]
      })
      Sentry.capture_exception(exception)
    end

    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end

  private

  def set_sentry_context
    return unless defined?(Sentry)

    Sentry.set_context("request", {
      url: request.url,
      method: request.method,
      remote_ip: request.remote_ip
    })

    # Tag by hostname for distributed system debugging
    Sentry.set_tag("hostname", request.host)
  end
end
