# Changelog

All notable changes to the ToggleFleet Ruby SDK are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — 2026-07-26

Reliability release. Every change here is about the SDK staying out of your
request path when something goes wrong.

### Fixed

- **A failed config fetch no longer blocks every flag check.** Previously, if the
  first fetch failed, `enabled?` retried the HTTP request on *every* call — so an
  unreachable config endpoint added up to `open_timeout + read_timeout` (8s by
  default) to each flag check, turning a background problem into a foreground
  outage. A failed attempt is now not retried until `refresh_interval` has
  elapsed; in between, evaluation returns `config.default` immediately with no
  network access at all.

- **Forked web servers now refresh their config.** Threads do not survive `fork`,
  so under Puma, Unicorn or Passenger in clustered mode every worker inherited a
  dead poller and served the boot-time configuration forever. The client now
  detects that it is running in a forked child and restarts the poller
  automatically — no `on_worker_boot` wiring required.

- **`ToggleFleet.configure` no longer leaks a thread.** Reconfiguring abandoned
  the previous client's poller, which kept running against the old config. The
  previous client is now stopped first. This mostly bit test suites, which
  reconfigure repeatedly.

### Added

- `ToggleFleet.stop` / `Client#stop` — cleanly terminate the background refresh
  thread. Safe to call more than once.
- Refresh interval is now jittered by ±15% so a fleet of processes that booted
  together does not poll the config endpoint in lockstep.

### Notes

- No API changes. Upgrading from 0.1.0 requires no code changes.
- Flag evaluation semantics are unchanged and remain byte-identical to
  server-side evaluation, including MD5 bucketing for sticky percentage rollouts.

## [0.1.0] — 2026-06-27

Initial release: local evaluation of all five gates (boolean, actor, group,
percentage of actors, percentage of time), background refresh with conditional
ETag requests, and fail-safe defaults.
