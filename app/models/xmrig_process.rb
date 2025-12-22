class XmrigProcess < ApplicationRecord
  STATUSES = %w[stopped starting running unhealthy stopping crashed restarting].freeze

  validates :hostname, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :worker_id, presence: true

  scope :active, -> { where(status: %w[starting running unhealthy]) }
  scope :needs_attention, -> { where(status: %w[crashed unhealthy]) }

  def healthy?
    status == "running" && last_health_check_at && last_health_check_at > 2.minutes.ago
  end

  def stale?
    last_health_check_at.nil? || last_health_check_at < 5.minutes.ago
  end

  def self.for_host(hostname)
    find_or_initialize_by(hostname: hostname) do |process|
      process.worker_id = "#{hostname}-production"
      process.status = "stopped"
    end
  end
end
