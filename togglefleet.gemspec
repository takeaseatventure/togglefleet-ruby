# frozen_string_literal: true

require_relative "lib/togglefleet/version"

Gem::Specification.new do |spec|
  spec.name        = "togglefleet"
  spec.version     = ToggleFleet::VERSION
  spec.authors     = ["ToggleFleet"]
  spec.email       = ["support@togglefleet.com"]

  spec.summary     = "Cloud feature flags for Ruby — all five gates, evaluated locally."
  # NOTE: rubygems.org does NOT render README.md — the gem page body is this
  # description and nothing else. Anything a developer needs in order to decide
  # whether to put this in their request path has to be said here.
  spec.description = <<~DESC
    ToggleFleet is a hosted feature-flag service for Ruby. This gem fetches your environment's
    flags once, refreshes them in the background with conditional ETag requests, and evaluates
    all five gates — boolean, actor, group, percentage-of-actors (sticky), and percentage-of-time
    — entirely in-process. Checking a flag is a hash lookup, not a network call, so flags cost
    nothing on the hot path and keep working at their last known values if ToggleFleet is
    unreachable.

    Zero runtime dependencies — only the Ruby standard library. Thread-safe, fork-safe under
    Puma/Unicorn/Passenger, and fail-safe by design: any error returns your configured default
    rather than raising into a request.

    Evaluation is byte-identical to server-side evaluation, including MD5 bucketing, so a sticky
    rollout targets exactly the same actors whether it is resolved locally or through the API.
    Group membership is decided by predicates in your own code, so no user data leaves your process.

    Requires a ToggleFleet account for an SDK key. Full documentation at https://togglefleet.com/docs.
  DESC
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
