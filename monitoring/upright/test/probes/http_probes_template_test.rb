require "test_helper"
require "erb"
require "yaml"

class HttpProbesTemplateTest < ActiveSupport::TestCase
  test "http probes template renders with nexum base url" do
    rendered = with_environment("NEXUM_APP_BASE_URL" => "http://localhost:3000") do
      ERB.new(File.read(Rails.root.join("probes/http_probes.yml.erb"))).result
    end

    probes = YAML.safe_load(rendered)
    urls = probes.map { |probe| probe.fetch("url") }

    assert_equal 3, probes.size
    assert_includes urls, "http://localhost:3000/up"
    assert_includes urls, "http://localhost:3000/ready"
    assert_includes urls, "http://localhost:3000/session/new"
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
