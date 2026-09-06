// Agent core contracts define the minimal plugin-facing agent request and response shapes.
import {
  Agent as CoreAgent,
  type AgentOptions as CoreAgentOptions,
} from "../../packages/agent-core/src/agent.js";
import type { AgentCoreRuntimeDeps } from "../../packages/agent-core/src/runtime-deps.js";
import type { CompleteSimpleFn, StreamFn } from "../../packages/llm-core/src/index.js";
import { completeSimple, streamSimple } from "./llm.js";

/** Runtime adapter that lets the package agent-core use OpenClaw LLM helpers. */
export const openClawAgentCoreRuntime = {
  completeSimple: completeSimple as unknown as CompleteSimpleFn,
  streamSimple: streamSimple as unknown as StreamFn,
} satisfies AgentCoreRuntimeDeps;

/** Agent-core class preconfigured with OpenClaw runtime dependencies. */
export class Agent extends CoreAgent {
  constructor(options: CoreAgentOptions = {}) {
    super({ runtime: openClawAgentCoreRuntime, ...options });
  }
}

// OpenClaw-owned reusable agent core
export * from "../../packages/agent-core/src/index.js";
// Proxy utilities
export * from "../agents/runtime/proxy.js";

/** Filter only supplied plugin tools through incumbent configuration policies.
 * No session key is accepted: this helper does not resolve conversation policy,
 * instantiate tools, discover plugins, or load workspace/session context.
 */
export async function filterConfiguredPluginTools(params: {
  config: import("../config/types.openclaw.js").OpenClawConfig;
  agentId: string;
  modelProvider: string;
  modelId: string;
  pluginId: string;
  tools: import("../agents/agent-tools.types.js").AnyAgentTool[];
}): Promise<import("../agents/agent-tools.types.js").AnyAgentTool[]> {
  const [{ resolveEffectiveToolPolicy }, pipeline, policy] = await Promise.all([
    import("../agents/agent-tools.policy.js"),
    import("../agents/tool-policy-pipeline.js"),
    import("../agents/tool-policy.js"),
  ]);
  const effective = resolveEffectiveToolPolicy({
    config: params.config,
    agentId: params.agentId,
    modelProvider: params.modelProvider,
    modelId: params.modelId,
  });
  return pipeline.applyToolPolicyPipeline({
    tools: params.tools,
    toolMeta: () => ({ pluginId: params.pluginId }),
    warn() {},
    auditLogLevel: "debug",
    steps: pipeline.buildDefaultToolPolicyPipelineSteps({
      ...effective,
      profilePolicy: policy.mergeAlsoAllowPolicy(
        policy.resolveToolProfilePolicy(effective.profile),
        effective.profileAlsoAllow,
      ),
      providerProfilePolicy: policy.mergeAlsoAllowPolicy(
        policy.resolveToolProfilePolicy(effective.providerProfile),
        effective.providerProfileAlsoAllow,
      ),
    }),
  });
}

/** Explicit provider-only invocation, without activating a plugin registry. */
export {
  withExplicitProviderRuntimeScope,
  assertExplicitProviderAdmission,
} from "../plugins/provider-runtime-scope.js";
/** Public descriptor adapter for the shipped Anthropic runtime implementation. */
export async function createBundledAnthropicProviderDescriptor(
  config: import("../config/types.openclaw.js").OpenClawConfig,
) {
  const { assertExplicitProviderAdmission } = await import("../plugins/provider-runtime-scope.js");
  assertExplicitProviderAdmission(config, "anthropic");
  const { buildAnthropicProvider } = await import("../../extensions/anthropic/register.runtime.js");
  return buildAnthropicProvider();
}

/** Metadata accompanying the exact shipped Anthropic descriptor; contains no credentials. */
export function createBundledAnthropicAuthLookupMaps() {
  return {
    aliasMap: {},
    envCandidateMap: { anthropic: ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"] },
    authEvidenceMap: {},
    setupProviderFallbackRefs: [],
  };
}
