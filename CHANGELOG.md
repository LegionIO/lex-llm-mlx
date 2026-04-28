# Changelog

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
