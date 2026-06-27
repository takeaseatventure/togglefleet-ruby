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
      @config  = config
      @groups  = {}            # name => predicate proc
      @flags   = {}            # flag key => state hash
      @etag    = nil
      @loaded  = false
      @mutex   = Mutex.new
      @poller  = nil
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
      sync
      @mutex.synchronize do
        @poller ||= Thread.new do
          loop do
            sleep(@config.refresh_interval)
            begin; sync; rescue StandardError => e; log("refresh failed: #{e.class}: #{e.message}"); end
          end
        end
        @poller.name = "togglefleet-refresh" if @poller.respond_to?(:name=)
      end
      self
    end

    # The whole point: evaluate locally, no network call here.
    def enabled?(flag, actor: nil, groups: nil)
      ensure_loaded
      state  = @mutex.synchronize { @flags[flag.to_s] }
      result = state ? evaluate(state, actor, groups) : @config.default
      @config.on_evaluation&.call(flag.to_s, actor, result)
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

    def ensure_loaded
      return if @loaded
      begin; sync; rescue StandardError => e; log("initial load failed, using defaults: #{e.message}"); end
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

    def log(msg)
      @config.logger&.warn("[togglefleet] #{msg}")
    end
  end

  class << self
    def configure
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
