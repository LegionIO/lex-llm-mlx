# lex-llm-mlx

LegionIO LLM provider extension for MLX-backed OpenAI-compatible servers on Apple Silicon.

This gem lives under `Legion::Extensions::Llm::Mlx` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

Load it with `require 'legion/extensions/llm/mlx'`.

## What It Provides

- `Legion::Extensions::Llm::Mlx::Provider`, registered as `:mlx`.
- OpenAI-compatible chat, streaming, model listing, and embeddings endpoint wrappers.
- Heuristic chat, embedding, and vision capability mapping for discovered local models.
- Local-first defaults for MLX servers running on MacBook, Mac Studio, or local Apple Silicon hosts.
- Best-effort `llm.registry` event publishing for readiness and model availability when transport is available.
- Shared Legion settings, JSON, and logging dependencies with full `Legion::Logging::Helper` integration.

## Architecture

```
Legion::Extensions::Llm::Mlx
  Mlx (module)             # Extension namespace, provider registration, default settings
  Provider                 # MLX provider — health, readiness, model listing, OpenAI-compatible adapter
  RegistryPublisher        # Async publisher for llm.registry readiness/model availability events
  RegistryEventBuilder     # Builds sanitized lex-llm registry envelopes for MLX provider state
  Transport::
    Messages::RegistryEvent  # AMQP message for llm.registry exchange
    Exchanges::LlmRegistry   # Topic exchange definition for llm.registry
```

## Default Settings

```ruby
Legion::Extensions::Llm::Mlx.default_settings
```

Defaults target `http://localhost:8000`, mark the provider as `:local`, and allow one concurrent local request. Fleet participation stays disabled unless the host opts in through `Legion::Settings`.

## Configuration

```ruby
Legion::Extensions::Llm.configure do |config|
  config.mlx_api_base = 'http://localhost:8000'
  config.mlx_api_key = ENV['MLX_API_KEY']
end
```

`mlx_api_key` is optional because most local MLX servers run without authentication. Set it when a proxy or hosted MLX gateway requires bearer authentication.

## Endpoint Helpers

- `completion_url` and `stream_url`: `/v1/chat/completions`
- `models_url`: `/v1/models`
- `embedding_url`: `/v1/embeddings`
- `health_url`: `/health`

The provider uses the shared `Legion::Extensions::Llm::Provider::OpenAICompatible` adapter so Legion routing can treat MLX, vLLM, OpenAI, and other compatible servers consistently while preserving provider-specific settings and health behavior.

## Registry Event Publishing

When `Legion::Transport` and `lex-llm` routing are available, the provider publishes best-effort events to the `llm.registry` topic exchange:

- **Readiness events** — published asynchronously when `readiness(live: true)` is called.
- **Model availability events** — published asynchronously after `list_models` discovers models.

Publishing is fire-and-forget in background threads; failures never block the provider.

## Dependencies

| Gem | Required | Purpose |
|-----|----------|---------|
| `legion-json` (>= 1.2.1) | Yes | JSON serialization |
| `legion-logging` (>= 1.3.2) | Yes | Structured logging via Helper |
| `legion-settings` (>= 1.3.14) | Yes | Configuration |
| `lex-llm` (>= 0.1.5) | Yes | Shared provider base, routing, fleet |

## Development

```bash
bundle install
bundle exec rspec       # 0 failures
bundle exec rubocop -A  # auto-fix
bundle exec rubocop     # lint check
```
