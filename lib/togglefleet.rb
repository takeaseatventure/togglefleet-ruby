# frozen_string_literal: true

require "net/http"
require "json"
require "digest"
require "uri"
require_relative "togglefleet/version"

# ToggleFleet — cloud feature flags for Ruby.
#
# Built from the ground up (Flipper's gate model as the reference, none of its code).
# Design goals: evaluate flags LOCALLY so there is zero network on the hot path, refresh
# the config in the background with conditional (ETag) requests, and fail safe.
#
#   ToggleFleet.configure { |c| c.sdk_key = ENV["TOGGLEFLEET_SDK_KEY"] }
#   ToggleFleet.register_group(:admins) { |user| user.admin? }
#   ToggleFleet.start                      # begin background refresh (optional but recommended)
#
#   ToggleFleet.enabled?(:checkout_v2, actor: current_user)   # => true / false
#
module ToggleFleet
  class Error < StandardError; end

  # The five gates, evaluated in order — first match wins (mirrors the server exactly).
  GATES = %i[boolean actor group percentage_of_actors percentage_of_time].freeze

  class Configuration
    attr_accessor :sdk_key, :url, :refresh_interval, :default,
                  :open_timeout, :read_timeout, :logger, :on_evaluation

    def initialize
      @sdk_key          = ENV["TOGGLEFLEET_SDK_KEY"]
      @url              = ENV.fetch("TOGGLEFLEET_URL", "https://togglefleet.com")
      @refresh_interval = Integer(ENV.fetch("TOGGLEFLEET_REFRESH", 15)) # seconds
      @default          = false   # fail-safe result when a flag is unknown or never fetched
      @open_timeout     = 3
      @read_timeout     = 5
      @logger           = nil
      @on_evaluation    = nil      # ->(flag, actor, result) {}  for metrics/logging
    end
  end

  # A self-contained client. Use ToggleFleet.* for the process-wide singleton, or build your
  # own (e.g. to talk to two environments at once): ToggleFleet::Client.new(config).
  class Client
    attr_reader :config

    def initialize(config)
      @config      = config
      @groups      = {}        # name => predicate proc
      @flags       = {}        # flag key => state hash
      @etag        = nil
      @loaded      = false
      @mutex       = Mutex.new
      @poller      = nil
      @poller_pid  = nil       # pid that owns @poller; threads do not survive fork
      @last_attempt = nil      # monotonic time of the last fetch attempt (success or failure)
    end

    # Register a group predicate. Group membership is decided in YOUR code, so a flag enabled
    # for :admins turns on for any actor where the block returns true.
    def register_group(name, &block)
      raise ArgumentError, "register_group needs a block" unless block
      @mutex.synchronize { @groups[name.to_s] = block }
      self
    end

    # Pull the config once and start the background refresh thread. Idempotent.
    def start
      attempt_sync
      start_poller
      self
    end

    # Stop the background refresh thread. Safe to call more than once.
    def stop
      thread = @mutex.synchronize do
        current = @poller
        @poller = nil
        @poller_pid = nil
        current
      end
      thread&.kill
      self
    end

    private def start_poller
      @mutex.synchronize do
        return if @poller && @poller_pid == Process.pid
        @poller = Thread.new do
          loop do
            # Jitter the interval so a fleet of processes that booted together
            # does not stampede the config endpoint in lockstep.
            sleep(@config.refresh_interval * (0.85 + Kernel.rand * 0.3))
            begin; sync; rescue StandardError => e; log("refresh failed: #{e.class}: #{e.message}"); end
          end
        end
        @poller.name = "togglefleet-refresh" if @poller.respond_to?(:name=)
        @poller_pid = Process.pid
      end
    end

    # Threads do not survive fork. Under Puma/Unicorn/Passenger in clustered
    # mode the workers inherit @loaded=true and a dead poller, so without this
    # they would serve the boot-time config forever and never refresh again.
    private def restart_poller_if_forked
      return if @poller_pid.nil? || @poller_pid == Process.pid
      @mutex.synchronize do
        @poller = nil
        @poller_pid = nil
      end
      start_poller
    end

    # The whole point: evaluate locally, no network call here.
    def enabled?(flag, actor: nil, groups: nil)
      restart_poller_if_forked
      ensure_loaded
      state  = @mutex.synchronize { @flags[flag.to_s] }
      result = state ? evaluate(state, actor, groups) : @config.default
      notify_evaluation(flag.to_s, actor, result)
      result
    rescue StandardError => e
      log("enabled?(#{flag}) error: #{e.class}: #{e.message}")
      @config.default
    end

    # Snapshot every known flag for an actor — handy for bootstrapping a JS client.
    def all(actor: nil, groups: nil)
      ensure_loaded
      keys = @mutex.synchronize { @flags.keys }
      keys.each_with_object({}) { |k, h| h[k] = enabled?(k, actor: actor, groups: groups) }
    end

    # Force a refresh now (returns true if the config changed).
    def sync
      uri = URI.join(@config.url + "/", "v1/config")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @config.open_timeout
      http.read_timeout = @config.read_timeout
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@config.sdk_key}"
      req["If-None-Match"] = @etag if @etag
      req["User-Agent"]    = "togglefleet-ruby/#{VERSION}"
      res = http.request(req)

      case res
      when Net::HTTPNotModified
        false
      when Net::HTTPSuccess
        flags = JSON.parse(res.body).fetch("flags", {})
        @mutex.synchronize { @flags = flags; @etag = res["ETag"]; @loaded = true }
        true
      when Net::HTTPUnauthorized
        raise Error, "invalid SDK key (401) — check config.sdk_key"
      else
        raise Error, "config fetch failed: HTTP #{res.code}"
      end
    end

    private

    # Lazy first load, rate-limited.
    #
    # Previously this retried on EVERY enabled? call while unloaded, so if the
    # config endpoint was unreachable each flag check blocked for open_timeout +
    # read_timeout (up to 8s) — turning a background outage into a foreground
    # one, which is the exact opposite of the gem's promise. Now a failed attempt
    # is not repeated until refresh_interval has elapsed; until then evaluation
    # returns config.default immediately with no network at all.
    def ensure_loaded
      return if @loaded
      return unless claim_attempt
      begin; sync; rescue StandardError => e; log("initial load failed, using defaults: #{e.message}"); end
    end

    # True at most once per refresh_interval. Deliberately records the attempt
    # before it happens, so a hung request cannot let a second caller through.
    def claim_attempt
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        return false if @last_attempt && (now - @last_attempt) < @config.refresh_interval
        @last_attempt = now
        true
      end
    end

    def attempt_sync
      return unless claim_attempt
      sync
    rescue StandardError => e
      log("initial load failed, using defaults: #{e.class}: #{e.message}")
    end

    # Mirrors the server's evaluation byte-for-byte (same MD5 bucketing) so a sticky rollout
    # is identical whether you evaluate here or call /v1/evaluate.
    def evaluate(state, actor, explicit_groups)
      return true if state["boolean"]

      aid = actor_id(actor)
      return true if aid && Array(state["actors"]).include?(aid)

      member_of = resolve_groups(actor, explicit_groups)
      return true unless (Array(state["groups"]) & member_of).empty?

      pa = state["percentage_of_actors"].to_i
      if pa.positive? && aid
        bucket = Digest::MD5.hexdigest("#{state['id']}:#{aid}")[0, 8].to_i(16) % 100
        return true if bucket < pa
      end

      pt = state["percentage_of_time"].to_i
      return true if pt.positive? && rand(100) < pt

      false
    end

    # Coerce an actor into a stable string id. Prefer an explicit #togglefleet_id, then #id,
    # else the value itself (so plain strings/symbols/ints work too).
    def actor_id(actor)
      return nil if actor.nil?
      return actor.togglefleet_id.to_s if actor.respond_to?(:togglefleet_id)
      return actor.id.to_s if actor.respond_to?(:id)
      actor.to_s
    end

    def resolve_groups(actor, explicit_groups)
      names = Array(explicit_groups).map(&:to_s)
      unless actor.nil?
        @mutex.synchronize { @groups.dup }.each do |name, predicate|
          begin
            names << name if predicate.call(actor)
          rescue StandardError => e
            log("group #{name} predicate raised: #{e.message}")
          end
        end
      end
      names.uniq
    end

    def notify_evaluation(flag, actor, result)
      @config.on_evaluation&.call(flag, actor, result)
    rescue StandardError => e
      log("on_evaluation callback raised: #{e.class}: #{e.message}")
    end

    def log(msg)
      @config.logger&.warn("[togglefleet] #{msg}")
    rescue StandardError
      nil
    end
  end

  class << self
    def configure
      # Stop the previous client first: reconfiguring used to abandon its poller
      # thread, which kept running forever against the old config — a thread and
      # socket leak every time configure was called (common in test suites).
      @client&.stop
      @config = Configuration.new
      yield @config if block_given?
      @client = Client.new(@config)
      @config
    end

    def config
      @config ||= Configuration.new
    end

    def client
      @client ||= Client.new(config)
    end

    def register_group(name, &block) = client.register_group(name, &block)
    def start = client.start
    def sync = client.sync
    def enabled?(flag, **opts) = client.enabled?(flag, **opts)
    def all(**opts) = client.all(**opts)

    # mostly for tests
    def reset!
      @config = nil
      @client = nil
    end
  end
end
