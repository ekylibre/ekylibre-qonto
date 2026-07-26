# frozen_string_literal: true

require 'vcr'

VCR.configure do |config|
  config.cassette_library_dir = File.expand_path('cassettes', __dir__)
  config.hook_into :webmock
  config.ignore_localhost = true
  # Any un-recorded outbound HTTP must fail loudly instead of hitting the
  # network — these are contract tests, not live calls.
  config.allow_http_connections_when_no_cassette = false
  config.default_cassette_options = { match_requests_on: %i[method uri] }
end
