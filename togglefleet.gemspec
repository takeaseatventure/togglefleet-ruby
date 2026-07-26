# frozen_string_literal: true

require_relative "lib/togglefleet/version"

Gem::Specification.new do |spec|
  spec.name        = "togglefleet"
  spec.version     = ToggleFleet::VERSION
  spec.authors     = ["ToggleFleet"]
  spec.email       = ["support@togglefleet.com"]

  spec.summary     = "Cloud feature flags for Ruby — all five gates, evaluated locally."
  spec.description = "ToggleFleet is a cloud feature-flag service. This gem fetches your " \
                     "environment's flags, caches them, and evaluates all five gates " \
                     "(boolean, actor, group, % of actors, % of time) locally — so checking a " \
                     "flag is a hash lookup, not a network call. Background refresh uses " \
                     "conditional ETag requests; evaluation is byte-identical to the server."
  spec.homepage    = "https://togglefleet.com"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # These become the sidebar links on rubygems.org/gems/togglefleet. Without
  # changelog_uri and bug_tracker_uri the page shows no way to see what changed
  # or where to report a problem, which reads as unmaintained.
  spec.metadata = {
    "homepage_uri"      => "https://togglefleet.com",
    "source_code_uri"   => "https://github.com/takeaseatventure/togglefleet-ruby",
    "documentation_uri" => "https://togglefleet.com/docs",
    "changelog_uri"     => "https://github.com/takeaseatventure/togglefleet-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri"   => "https://github.com/takeaseatventure/togglefleet-ruby/issues",
    "rubygems_mfa_required" => "true"
  }
end
