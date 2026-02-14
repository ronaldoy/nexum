class CspReportsController < ActionController::Base
  skip_forgery_protection

  def create
    report = normalized_report_payload
    Rails.logger.warn(
      "csp_violation request_id=#{request.request_id} blocked_uri=#{report['blocked-uri']} " \
      "violated_directive=#{report['violated-directive']} effective_directive=#{report['effective-directive']} " \
      "source_file=#{report['source-file']} line_number=#{report['line-number']}"
    )

    head :no_content
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def normalized_report_payload
    payload = request.request_parameters.presence || JSON.parse(request.raw_post)
    report = payload["csp-report"] || payload["csp_report"] || payload
    report.is_a?(Hash) ? report : {}
  end
end
