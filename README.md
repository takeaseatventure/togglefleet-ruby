# ToggleFleet — Ruby SDK

Cloud feature flags for Ruby. All five gates — **boolean, actor, group, % of actors, % of time** —
evaluated **locally** in your process, so checking a flag is a hash lookup, not a network round-trip.
The gem refreshes your environment's config in the background using conditional (ETag) requests, and
its percentage bucketing is byte-identical to the server, so a sticky rollout is the same whether you
evaluate in-app or via the REST API.

```ruby
gem "togglefleet"
```

## Quick start

```ruby
# config/initializers/togglefleet.rb
ToggleFleet.configure do |c|
  c.sdk_key          = ENV["TOGGLEFLEET_SDK_KEY"]  # one key per environment (Settings → SDK keys)
  c.refresh_interval = 15                          # seconds between background refreshes
  c.default          = false                       # fail-safe value if a flag is unknown
end

# Group membership is decided in YOUR code:
ToggleFleet.register_group(:admins)   { |user| user.admin? }
ToggleFleet.register_group(:internal) { |user| user.email.end_with?("@yourco.com") }

ToggleFleet.start  # initial fetch + background refresh thread (recommended)
```

```ruby
# anywhere in your app — no network call happens here
if ToggleFleet.enabled?(:checkout_v2, actor: current_user)
  render "checkout/v2"
end
```

## The gates

A flag is **on** for an actor if **any** gate matches (first match wins):

| Gate | Turn it on in the dashboard | Effect |
|------|------------------------------|--------|
| Boolean | "Fully on" | on for everyone |
| Actor | add actor IDs | on for those specific actors |
| Group | add group names | on for actors your registered predicate matches |
| % of actors | set 0–100 | sticky — the same actors keep it as you ramp |
| % of time | set 0–100 | random per call |

## Actors

An "actor" is anything you want to flag on. The gem derives a stable id:

1. `actor.togglefleet_id` if defined, else
2. `actor.id` (works out of the box for ActiveRecord), else
3. the value itself (so a plain string, symbol, or integer works).

```ruby
ToggleFleet.enabled?(:beta, actor: current_user)   # uses current_user.id
ToggleFleet.enabled?(:beta, actor: "account_42")   # plain string id
ToggleFleet.enabled?(:beta)                         # no actor: boolean / % of time only
```

You can also pass groups explicitly (in addition to registered predicates):

```ruby
ToggleFleet.enabled?(:eu_pricing, actor: user, groups: [:eu_customer])
```

## Bulk snapshot

Resolve every flag at once — useful for handing state to a front end:

```ruby
ToggleFleet.all(actor: current_user)
# => { "checkout_v2" => true, "dark_mode" => false, ... }
```

## Reliability

- **Local evaluation** — `enabled?` never blocks on the network.
- **Background refresh** — a single daemon thread polls every `refresh_interval` seconds with an
  `If-None-Match` ETag, so unchanged configs cost one `304` and zero parsing.
- **Fail-safe** — if the service is unreachable, the gem serves the last good config; if it never
  loaded, every flag returns `config.default` (defaults to `false`).
- **Instrumentation** — hook every evaluation for metrics or logging:

```ruby
ToggleFleet.configure do |c|
  c.sdk_key = ENV["TOGGLEFLEET_SDK_KEY"]
  c.on_evaluation = ->(flag, actor, result) { StatsD.increment("flag.#{flag}.#{result}") }
end
```

## Multiple environments at once

The module-level `ToggleFleet.*` is a singleton, but you can build standalone clients:

```ruby
prod = ToggleFleet::Client.new(ToggleFleet::Configuration.new.tap { |c| c.sdk_key = ENV["PROD_KEY"] }).start
staging = ToggleFleet::Client.new(ToggleFleet::Configuration.new.tap { |c| c.sdk_key = ENV["STAGING_KEY"] }).start
```

## REST API (any language)

No Ruby? Hit the API directly with an environment's SDK key.

```
GET /v1/evaluate?flag=checkout_v2&actor=dave&groups=admins
Authorization: Bearer tf_live_…
→ { "flag": "checkout_v2", "enabled": true }

GET /v1/config
Authorization: Bearer tf_live_…
→ { "flags": { "checkout_v2": { "boolean": false, "percentage_of_actors": 25,
      "percentage_of_time": 0, "actors": ["dave"], "groups": ["admins"], "id": "…" } } }
```

`/v1/config` returns the whole environment so you can cache and evaluate locally (that's what this
gem does). `/v1/evaluate` does a single server-side check — note that **group** gates are resolved
client-side, so pass `groups=` when using `/v1/evaluate`.

## License

MIT © ToggleFleet
