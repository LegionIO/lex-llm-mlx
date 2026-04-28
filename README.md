# lex-llm-mlx

LegionIO LLM provider extension for MLX-backed OpenAI-compatible servers on Apple Silicon.

This gem lives under `Legion::Extensions::Llm::Mlx` and depends on `lex-llm` for shared provider-neutral routing, fleet, and schema primitives.

Load it with `require 'legion/extensions/llm/mlx'`.

## What It Provides

- `Legion::Extensions::Llm::Mlx::Provider`, registered as `:mlx`.
- OpenAI-compatible chat, streaming, model listing, and embeddings endpoint wrappers.
- Local-first defaults for MLX servers running on MacBook, Mac Studio, or local Apple Silicon hosts.
- Shared Legion settings, JSON, and logging dependencies.

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
