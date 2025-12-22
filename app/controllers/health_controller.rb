# Custom health check controller
# Supports both simple checks (no DB) and full checks (with DB)
class HealthController < ApplicationController
  def show
    # Check if we should skip database checks (for initial deployment)
    skip_db = params[:skip_db] == "true" || ENV["HEALTH_CHECK_SKIP_DB"] == "true"

    checks = {
      status: "ok",
      timestamp: Time.current.iso8601
    }

    unless skip_db
      # Check database connectivity
      begin
        ActiveRecord::Base.connection.execute("SELECT 1")
        checks[:database] = "connected"
      rescue => e
        checks[:database] = "error"
        checks[:database_error] = e.message
        return render json: checks, status: :service_unavailable
      end
    end

    render json: checks, status: :ok
  rescue => e
    render json: {
      status: "error",
      error: e.message,
      timestamp: Time.current.iso8601
    }, status: :service_unavailable
  end
end
