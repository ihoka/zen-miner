# frozen_string_literal: true

module Installer
  # Result object for installation steps
  # Provides a consistent interface for success/failure tracking
  class Result
    attr_reader :success, :message, :data

    def initialize(success:, message:, data: {})
      @success = success
      @message = message
      @data = data
    end

    def success? = @success
    def failure? = !@success

    def self.success(message, data: {})
      new(success: true, message: message, data: data)
    end

    def self.failure(message, data: {})
      new(success: false, message: message, data: data)
    end
  end
end
