# frozen_string_literal: true

require 'faraday'

require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/mlx/provider'

module Legion
  module Extensions
    module Llm
      module Mlx
        module Helpers
          # Callable wrapper for an MLX provider instance. It is the
          # exact-execution dispatch target: it implements the fleet dispatch
          # operations (chat, stream_chat, embed, count_tokens) by delegating
          # to a per-instance Mlx::Provider built from the instance config,
          # plus the `disconnect` and `normalize_dispatch_error(error:)`
          # contracts required by Inventory::CallableHandle and
          # Routing::ProviderOutcome. Provider and Faraday errors are NOT
          # rescued here so the dispatch normalizer can classify them.
          # 0.8.0 callable contract: chat/stream_chat take the rehydrated
          # message array positionally (WorkerExecution dispatch shape) and
          # the Selection-derived model as a bare String.
          class Callable
            # Keys the base Provider exposes as named kwargs for the
            # completion operations. Anything else the fleet passes (sampling
            # scalars, `temperature` — a Canonical::Params member, 05 O4) is
            # folded into Canonical::Params at the dispatch boundary.
            COMPLETION_NAMED_KEYS = %i[tools schema thinking tool_prefs headers].freeze
            EMBED_NAMED_KEYS = %i[dimensions headers].freeze

            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
              @inference_calls = 0
            end

            def call_count
              @inference_calls
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[mlx][callable] disconnected' }
            end

            # ── Fleet dispatch operations ───────────────────────────────────

            def chat(messages, model:, **rest)
              record_inference
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash/legacy shapes are the
              # bypass class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **rest, &)
              record_inference
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def embed(text:, model:, **rest)
              record_inference
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model, params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              record_inference
              provider.enforce_canonical_messages!(messages)
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]
              kind = classify_error_kind(error: error)

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def record_inference
              @inference_calls += 1
            end

            def provider
              @provider ||= Legion::Extensions::Llm::Mlx::Provider.new(@instance_cfg)
            end

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at
            # the dispatch boundary — temperature is a params member (05 O4),
            # never a kwarg.
            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            # Split the fleet's **rest into the base Provider's named kwargs
            # and a payload params hash (any passed :params merged with
            # unknown keys).
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
            end

            def classify_error_kind(error:)
              case error
              when Faraday::ConnectionFailed then :connection_failure
              when Faraday::TimeoutError then :timeout
              when Faraday::ClientError then classify_client_error(error: error)
              when Faraday::ServerError then classify_server_error(error: error)
              when Legion::Extensions::Llm::OverloadedError then :overloaded
              else :provider_error
              end
            end

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/529/5xx as instance_unavailable by status alone.
              # Only an explicit flat MLX service/instance-unavailable signal (which MLX
              # does not produce) would justify instance_unavailable. For MLX, connection
              # failure (port unreachable) is the signal the instance is down.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end
