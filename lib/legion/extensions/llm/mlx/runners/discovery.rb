# frozen_string_literal: true

require 'time'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/mlx/helpers/callable'
require 'legion/extensions/llm/mlx/provider'

module Legion
  module Extensions
    module Llm
      module Mlx
        module Runners
          # MLX discovery runner: ONLY the MLX-specific work. The generic
          # reconcile / claim / activate / probe (cadence + reactive) / replace /
          # weight-publication / health-display pipeline is mixed in from the
          # shared Discovery::Pipeline. Weight is NOT computed here — the
          # shared WeightReconciler recomputes it from live settings at publish.
          #
          # The catalog is OpenAI-shaped (GET /v1/models -> body[:data]) and
          # readiness is GET /health, so the pipeline's default
          # fetch_raw_models / model_id_from / check_health / health_path are
          # reused. The overrides are the MLX config keys (mlx_api_base /
          # mlx_api_key, defaulting to http://localhost:8000), the
          # Helpers::Callable, and the offering-draft evidence.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            EMBEDDING_PATTERN = /embed|bge|e5|nomic/i
            # Protocol-required evidence source: the default_false taxonomy member.
            UNKNOWN_EVIDENCE_SRC = :default_false

            # ── MLX instance-config keys / connection ───────────────────────
            # Mlx.normalize_instance_config promotes endpoint/base_url/api_base
            # aliases to :mlx_api_base; a missing base falls back to the
            # extension's registered localhost default.
            def catalog_base_url(instance_cfg:)
              normalize_api_base(instance_cfg[:mlx_api_base] || instance_cfg[:endpoint] || 'http://localhost:8000')
            end

            # MLX is local: auth is an OPTIONAL bearer key (mlx_api_key, or
            # credentials.api_key when no explicit key is set).
            def auth_token(instance_cfg:)
              token = instance_cfg[:mlx_api_key] || instance_cfg.dig(:credentials, :api_key)
              token if token.is_a?(String) && !token.strip.empty?
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Mlx::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :local
              embed_supported = embedding_model?(model_id: model_id)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported, model_id: model_id),
                capability_evidence: build_capability_evidence(model_id: model_id),
                context_evidence: build_context_evidence(model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  model_data: model_data, embed_supported: embed_supported
                ),
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_data: model_data, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            private

            def embedding_model?(model_id:)
              model_id.to_s.match?(EMBEDDING_PATTERN)
            end

            def build_operation_evidence(embed_supported:, **)
              now = Time.now.freeze
              is_embedding = embed_supported
              {
                chat: op_evidence(operation: :chat, status: is_embedding ? :unsupported : :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: is_embedding ? :unsupported : :supported,
                                         observed_at: now),
                embed: op_evidence(operation: :embed, status: is_embedding ? :supported : :unsupported,
                                   observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? UNKNOWN_EVIDENCE_SRC : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(model_id:)
              is_embedding = embedding_model?(model_id: model_id)
              caps = {
                completion: cap_evidence(capability: :completion,
                                         status: is_embedding ? :unsupported : :supported,
                                         source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming,
                                        status: is_embedding ? :unsupported : :supported,
                                        source: :provider_implementation),
                tools: cap_evidence(capability: :tools, status: :unknown, source: UNKNOWN_EVIDENCE_SRC),
                thinking: cap_evidence(capability: :thinking, status: :unknown, source: UNKNOWN_EVIDENCE_SRC)
              }

              if is_embedding
                caps[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end

              caps
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end

            def build_context_evidence(model_data:)
              ctx = model_data[:max_model_len] || model_data[:context_length]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:max_output_tokens] || model_data[:max_completion_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(model_data:, embed_supported:)
              unless embed_supported
                return Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end

              dims = model_data[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims.uniq.sort, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: model_data[:id].to_s }
              meta[:parameter_count] = model_data[:parameter_count] if model_data[:parameter_count]
              meta[:quantization] = model_data[:quantization].to_s if model_data[:quantization]
              meta[:instance_id] = instance_key.instance_id
              meta
            end
          end
        end
      end
    end
  end
end
