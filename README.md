# lex-llm-mlx

LegionIO LLM provider extension for MLX-backed OpenAI-compatible servers on Apple Silicon.

This gem lives under `Legion::Extensions::Llm::Mlx` and depends on `lex-llm >= 0.4.3` for shared provider-neutral routing, response normalization, fleet envelopes, fleet responder execution, and schema primitives.

Load it with `require 'legion/extensions/llm/mlx'`.

## What It Provides

- `Legion::Extensions::Llm::Mlx::Provider`, exposed to `legion-llm` as the `:mlx` provider family.
- OpenAI-compatible chat, streaming, model listing, and embeddings endpoint wrappers.
- Heuristic chat, embedding, and vision capability mapping for discovered local models.
- Local-first defaults for MLX servers running on Apple Silicon hosts.
- Best-effort `llm.registry` event publishing through shared `lex-llm` registry helpers when transport is available.
- Provider-owned fleet request actor and runner backed by `lex-llm`.
- Shared Legion settings, JSON, and logging dependencies with full `Legion::Logging::Helper` integration.

## Architecture

```
Legion::Extensions::Llm::Mlx
  Mlx                          # Extension namespace, discovery metadata, default settings
  Provider                     # Health, readiness, model listing, OpenAI-compatible adapter
  Actor::FleetWorker           # Subscription actor enabled by provider instance fleet settings
  Runners::FleetWorker         # Delegates fleet execution to Legion::Extensions::Llm::Fleet::ProviderResponder
  (shared from lex-llm)
    RegistryPublisher          # Async llm.registry event publishing
    RegistryEventBuilder       # Sanitized registry envelope construction
```

The extension no longer writes provider adapters into the registry at require time. Loaded provider discovery metadata is consumed by `legion-llm`, which owns adapter creation and registry writes.

## Default Settings

```ruby
Legion::Extensions::Llm::Mlx.default_settings
```

Defaults target `http://localhost:8000`, mark the default instance as `:local`, allow one concurrent local request, and keep fleet participation disabled until a host opts in through extension settings.

## Configuration

The provider accepts the shared `lex-llm` configuration options:

```ruby
Legion::Extensions::Llm.configure do |config|
  config.mlx_api_base = 'http://localhost:8000'
  config.mlx_api_key = ENV['MLX_API_KEY']
end
```

`mlx_api_key` is optional because most local MLX servers run without authentication. Set it when a proxy or hosted MLX gateway requires bearer authentication.

Provider discovery also reads named instances from `extensions.llm.mlx.instances`. Generic keys are normalized for the MLX provider:

```yaml
extensions:
  llm:
    mlx:
      instances:
        local:
          base_url: http://localhost:8000
          api_key: null
          fleet:
            enabled: false
            respond_to_requests: false
            capabilities:
              - chat
              - stream_chat
              - embed
```

Accepted instance URL keys are `base_url`, `api_base`, `endpoint`, or `mlx_api_base`. A trailing `/v1` is stripped because the shared OpenAI-compatible adapter appends endpoint paths itself.

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

```yaml
extensions:
  llm:
    mlx:
      instances:
        local:
          base_url: http://localhost:8000
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

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

## Failure Modes

- `readiness(live: true)` calls the MLX `/health` endpoint and publishes readiness metadata only when the live check succeeds.
- `list_models` expects an OpenAI-compatible `/v1/models` response and publishes discovered model availability through the shared registry publisher.
- Fleet request handling is disabled unless at least one discovered instance opts in with `fleet.respond_to_requests: true`.
- Local instance discovery checks `localhost:8080`; explicitly configured instances can point at any OpenAI-compatible MLX endpoint.

## Dependencies

| Gem | Required | Purpose |
|-----|----------|---------|
| `legion-json` (>= 1.2.1) | Yes | JSON serialization |
| `legion-logging` (>= 1.3.2) | Yes | Structured logging via Helper |
| `legion-settings` (>= 1.3.14) | Yes | Configuration |
| `lex-llm` (>= 0.4.3) | Yes | Shared provider base, response normalization, routing, fleet envelopes, and fleet responder execution |
| `legion-transport` (>= 1.4.14) | Yes | AMQP subscriptions and replies |

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```
