class XmrigCommand < ApplicationRecord
  ACTIONS = %w[start stop restart].freeze
  STATUSES = %w[pending processing completed failed].freeze

  validates :action, :status, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending").order(:created_at) }
  scope :recent, -> { where(created_at: 1.hour.ago..) }

  def mark_processing!
    update!(status: "processing", processed_at: Time.current)
  end

  def mark_completed!(result = nil)
    update!(status: "completed", result: result)
  end

  def mark_failed!(error)
    update!(status: "failed", error_message: error)
  end
end
