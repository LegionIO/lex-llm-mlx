# Changelog

## [0.5.3] - 2026-08-19

### Changed
- Publish the immutable four-component lane-weight pair from MLX discovery and reconcile weight-only changes on the existing scheduled writer pass.
- Serialize initial, recovery, replacement, removal, and shutdown state transitions behind one actor-local mutex without adding a Settings callback or operator workflow.
- Track configured-but-unpublished weight keys on the existing discovery cadence and log each dormant transition once.
- Raise the `lex-llm` dependency floor to 0.7.6; the existing `legion-settings` dependency remains unchanged.

### Fixed
- Compare every offering contract field while excluding only non-authoritative evidence observation timestamps, preventing unchanged discovery passes from republishing snapshots while retaining real evidence and weight changes.

### Added
- Cover the complete writer lifecycle, publication races, failure atomicity, dormant-state cycle, and the actual callable's folded-system OpenAI-compatible wire payload.

## [0.5.2] - 2026-08-18

### Fixed
- Remove synthetic-default discovery filtering and its once-per-boot warning; configured discovery now returns every instance entry.

## [0.5.1] - 2026-08-17

### Changed
- **Single actor registration** — the provider module no longer extends `Core` at file level, so the
  boot-time submodule walk skips it and the gem's own top-level extension load is the sole actor
  registration (eliminates the double-claim / `FencedPublisherError`).
- The synthetic-default skip warn now fires once per boot instead of every discovery tick (was
  permanent WARN noise — an unconfigured provider is the normal state).
- **SSOT v3 fail-forward identity** — Instance identity is now the operator's config name
  (`InstanceKey.instance_id` = the frozen config key the router uses for `instances.<name>`
  lookups). The normalized endpoint `host:port` (plus optional API key SHA256 fingerprint) is
  carried as the secondary `physical_id` for dedup and diagnostics only, never identity.
  Two config names at the same endpoint remain distinct instances (no endpoint collapse).
  All `Inventory::Publisher` calls now pass `physical_id:`.
- Bump floor to `lex-llm >= 0.7.1` (carries the SSOT v3 `InstanceKey` `physical_id` and the
  Publisher `physical_id:` kwargs; 0.7.0 publishers reject the `physical_id:` kwarg).

### Added
- Conformance coverage for config-name identity, secondary physical id, and no endpoint
  collapse, plus an authoritative operation-evidence check pinning that embedding models
  publish `chat`/`stream_chat` as `:unsupported` and `embed` as `:supported` so a plain chat
  request cannot misroute to an embedding-only instance.

## [0.5.0] - 2026-08-13

### Changed
- **SSOT v3 remediation pass 2** — Resolve all residual compliance violations from the first pass.
- Remove source obfuscation: `UNKNOWN_EVIDENCE_SRC` constant restored to plain `:default_false` literal.
- Remove second publication engine: `registry_publisher` class method and `attr_writer` removed from
  `Provider`; `readiness` and `list_models` no longer call `publish_readiness_async` /
  `publish_models_async` on the old `RegistryPublisher`. Single SSOT v3 `Inventory::Publisher` path only.
- Remove regex-based authoritative capability claims: `extract_catalog_capabilities` and
  `provider_envelope_capabilities` no longer promote model-name regex matches or hardcode streaming;
  unverified capability support is unknown, not promoted to supported.
- Fix `.rubocop.yml`: remove `RSpec/SpecFilePathFormat` `Exclude` entry for capability spec; rename
  spec to `provider_capability_policy_spec.rb` to satisfy the path format cop cleanly.
- Fix `settings.dig(:credentials, :api_key)` → `settings[:credentials][:api_key]` per §1.
- Fix `settings[:endpoint] || 'http://localhost:8000'` → `settings[:endpoint]` (registered default).
- Fix `api_base` to read the registered default from `settings[:instances][:default][:endpoint]`.
- Fix swallowed `URI::InvalidURIError` rescue in `extract_host_port`: call `handle_exception` + re-raise.
- Add `handle_exception` to `check_health` `Faraday::ConnectionFailed` and `StandardError` rescues.

## [0.4.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** — Complete rewrite of `DiscoveryRefresh` actor to use `Inventory::Publisher`,
  `OfferingDraft`, `ProbeCoordinator`, and `ReadinessResult` from lex-llm 0.7.0.
- Add `MlxCallable` with `disconnect` / `normalize_dispatch_error(error:)` contracts for
  `Inventory::CallableHandle` and `Routing::ProviderOutcome`.
- Instance identity derived from normalized endpoint `host:port` plus optional API key SHA256 fingerprint.
- Readiness probed via `/health` (non-inference, non-billable).
- Embedding detection via model name pattern (`/embed|bge|e5|nomic/i`).
- Operations: chat/stream_chat supported for non-embedding models; embed supported only for embedding models;
  image/transcribe/translate/speak/moderate unsupported; count_tokens unknown.
- Fleet worker passes `registry:` kwarg to `ProviderResponder.call` for exact-offering execution.
- Remove all references to `Legion::LLM::Call::Registry` and `ScopedRefresher`.
- Bump floor to `lex-llm >= 0.7.0`.

### Added
- Full SSOT v3 conformance spec (`mlx_ssot_v3_conformance_spec.rb`) exercising the shared
  `'an SSOT v3 provider adapter'` examples plus MLX-specific identity, embedding, isolation,
  and fleet execution contract tests.

## [0.3.14] - 2026-08-04

### Changed
- Prepare the MLX provider standardization baseline for a patch release.

## [0.3.13] - 2026-06-20

### Changed
- Align MLX offerings to the current `lex-llm` contract: `discover_offerings` now works with the shared
  provider flow, offerings honor configured tier/transport overrides, and provider health is carried onto
  discovered offerings in the shared shape.
- Normalize MLX capability override expectations to the shared `:embedding` offering vocabulary.

## [0.3.12] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.3.11 - 2026-06-16

- Dependency updates and code quality improvements.

## 0.3.10 - 2026-06-15

- **CapabilityPolicy integration** — Name-pattern heuristics tagged as `:provider_catalog`; streaming from `:provider_envelope`. Settings overrides at provider/instance/model level supported.

## 0.3.9 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Dependency bump** — Require `lex-llm >= 0.5.0` for canonical types support.
- **Canonical tool support** — Use `ToolSchema.extract` and add `:tools` capability.
- 20 examples, 0 failures; 13 files, 0 rubocop offenses.

## 0.3.8 - 2026-06-02

- Add per-provider scoped discovery refresh actor

## 0.3.7 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations
- api_base reads from settings[:endpoint] fallback
- Identity headers included via base provider


## 0.3.6 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.3.5 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical MLX provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Gate release publishing on the shared security workflow.

## 0.3.4 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.3.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.3.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract and accept `health(live:)`.
- Move MLX defaults back to `Legion::Extensions::Llm.provider_settings` with instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.3.1 - 2026-05-03

- Normalize generic settings keys to MLX provider config keys during instance discovery.
- Strip trailing `/v1` from configured OpenAI-compatible MLX API roots.

## 0.3.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## 0.2.0 - 2026-04-30

- Adopt lex-llm 0.1.9 base contract for RegistryPublisher and RegistryEventBuilder.
- Remove local `RegistryPublisher` and `RegistryEventBuilder` classes in favor of parameterized base versions.
- Remove local `transport/` directory (exchange and message classes) in favor of shared lex-llm transport layer.
- Remove deprecated `Provider.register` call; register configuration options directly.
- Replace `provider_settings` builder with flat `default_settings` hash matching the new consumer contract.
- Bump gemspec dependency to `lex-llm >= 0.1.9`.

## 0.1.7 - 2026-04-30

- Add `Legion::Logging::Helper` to `Mlx` module and `RegistryPublisher` for standardized logging.
- Replace all bare rescue blocks with `handle_exception` calls for full observability.
- Add info-level action logging for health checks, readiness, model discovery, and registry publishing.
- Remove custom `log_publish_failure` method in favor of `handle_exception`.
- Update README to document registry event publishing, transport layer, and architecture.

## 0.1.6 - 2026-04-28

- Publish best-effort `llm.registry` live readiness and discovered-model availability events using `lex-llm` registry envelopes when transport is already available.

## 0.1.5 - 2026-04-28

- Require current shared Legion JSON, logging, settings, and `lex-llm >= 0.1.5` runtime dependencies.

## 0.1.4 - 2026-04-28

- Require `lex-llm >= 0.1.4` so OpenAI-compatible model discovery exposes normalized capabilities and modalities.
- Add explicit chat and embedding model capability mapping for MLX routing metadata.

## 0.1.3 - 2026-04-28

- Remove the leftover compatibility entrypoint outside the Legion namespace.
- Load specs through the canonical `legion/extensions/llm/mlx` namespace path.
- Keep provider gemspec dependencies scoped to the shared `lex-llm` base gem.

## 0.1.2 - 2026-04-28

- Replace fork-era namespace references with the standard Legion::Extensions::Llm provider contract.
- Remove GitHub-based lex-llm Gemfile fallback so test installs use only a guarded local path or released gem dependency.
- Require lex-llm >= 0.1.3 for the cleaned Legion-native base extension.

## 0.1.1 - 2026-04-27

- Add a local MLX OpenAI-compatible provider class with chat, streaming, model listing, embeddings, and health endpoint helpers.
- Move provider defaults to shared `lex-llm` settings construction and add shared Legion runtime dependencies.
- Remove the tracked Bundler lockfile from the provider gem.

## 0.1.0 - 2026-04-26

- Initial Legion LLM Mlx provider extension scaffold.
