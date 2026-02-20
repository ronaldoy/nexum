require "test_helper"
require "erb"
require "yaml"

class DeployConfigTest < ActiveSupport::TestCase
  test "deploy config renders valid yaml with required environment variables" do
    rendered = with_environment(
      "UPRIGHT_WEB_HOST" => "upright.example.com",
      "UPRIGHT_JOB_HOST" => "upright-jobs.example.com",
      "UPRIGHT_HOSTNAME" => "upright.example.com",
      "KAMAL_REGISTRY_USERNAME" => "nexum-ci"
    ) do
      ERB.new(File.read(Rails.root.join("config/deploy.yml"))).result
    end

    parsed = YAML.safe_load(rendered, aliases: true)

    assert_equal "nexum-upright", parsed.fetch("service")
    assert_equal "nexum-capital/nexum-upright", parsed.fetch("image")
    assert_equal [ "app.upright.example.com", "gru.upright.example.com" ], parsed.dig("proxy", "hosts")
    assert_equal "upright.example.com", parsed.dig("servers", "web", "hosts").first.keys.first
  end

  private

  def with_environment(overrides)
    previous = {}
    overrides.each do |key, value|
      previous[key] = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
