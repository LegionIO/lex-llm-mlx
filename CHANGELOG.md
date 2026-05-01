# Changelog

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
