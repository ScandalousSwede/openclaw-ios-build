// Agent core contracts define the minimal plugin-facing agent request and response shapes.
import {
  Agent as CoreAgent,
  type AgentOptions as CoreAgentOptions,
} from "../../packages/agent-core/src/agent.js";
import type { AgentCoreRuntimeDeps } from "../../packages/agent-core/src/runtime-deps.js";
import type { CompleteSimpleFn, StreamFn } from "../../packages/llm-core/src/index.js";
import type { ExplicitProviderRuntimeScope } from "../plugins/provider-runtime-scope.js";
import { completeSimple, streamSimple } from "./llm.js";

/** Runtime adapter that lets the package agent-core use OpenClaw LLM helpers. */
export const openClawAgentCoreRuntime = {
  completeSimple: ((model, context, options) =>
    completeSimple(model, context, options)) satisfies CompleteSimpleFn,
  streamSimple: ((model, context, options) =>
    streamSimple(model, context, options)) satisfies StreamFn,
} satisfies AgentCoreRuntimeDeps;

/** Agent-core class preconfigured with OpenClaw runtime dependencies. */
export class Agent extends CoreAgent {
  constructor(options: CoreAgentOptions = {}) {
    super({ runtime: openClawAgentCoreRuntime, ...options });
  }
}

// OpenClaw-owned reusable agent core
export { runAgentLoop } from "../../packages/agent-core/src/index.js";
// Documented proxy stream API stays until this entrypoint's announced
// public demotion window (registry: plugin-sdk-agent-core-public-demotion).
export { streamProxy } from "../agents/runtime/proxy.js";
export type { ProxyAssistantMessageEvent, ProxyStreamOptions } from "../agents/runtime/proxy.js";
export {
  bashExecutionToText,
  buildSessionContext,
  calculateContextTokens,
  collectEntriesForBranchSummaryFromBranches,
  compact,
  estimateContextTokens,
  estimateTokens,
  findCutPoint,
  findTurnStartIndex,
  generateBranchSummary,
  generateSummary,
  getLastAssistantUsage,
  prepareBranchEntries,
  prepareCompaction,
  serializeConversation,
  shouldCompact,
  uuidv7,
  BRANCH_SUMMARY_PREFIX,
  BRANCH_SUMMARY_SUFFIX,
  COMPACTION_SUMMARY_PREFIX,
  COMPACTION_SUMMARY_SUFFIX,
  DEFAULT_COMPACTION_SETTINGS,
  IMAGE_BLOCK_TOKENS,
} from "../../packages/agent-core/src/index.js";
export type {
  AfterToolCallResult,
  AfterToolOutcomeContext,
  AgentEvent,
  AgentMessage,
  AfterToolCallContext,
  AgentOptions,
  AgentState,
  AgentTool,
  AgentToolProgress,
  AgentToolResult,
  AgentToolUpdateCallback,
  BashExecutionMessage,
  BranchPreparation,
  BranchSummaryDetails,
  BranchSummaryResult,
  CompactionDetails,
  CompactionPreparation,
  CompactionResult,
  CompactionSettings,
  CompactionSummaryPrompt,
  ContextUsageEstimate,
  FileOperations,
  Result,
  SessionTreeEntry,
  StreamFn,
  ThinkingLevel,
  ToolExecutionMode,
} from "../../packages/agent-core/src/index.js";
// Proxy utilities

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
  return loadReviewedProviderDescriptor("anthropic");
}

/** Metadata accompanying the exact shipped Anthropic descriptor; contains no credentials. */
export function createBundledAnthropicAuthLookupMaps() {
  return {
    aliasMap: { "claude-cli": "anthropic" },
    envCandidateMap: { anthropic: ["ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"] },
    authEvidenceMap: {},
    setupProviderFallbackRefs: [],
  };
}

/** Exact shipped model alias metadata; no registry discovery. */
export async function createBundledAnthropicModelMetadata(
  config: import("../config/types.openclaw.js").OpenClawConfig,
) {
  const { assertExplicitProviderAdmission } = await import("../plugins/provider-runtime-scope.js");
  assertExplicitProviderAdmission(config, "anthropic");
  const { loadBundledPluginPublicSurfaceManifest } = await import("./facade-loader.js");
  return [
    await loadBundledPluginPublicSurfaceManifest({ dirName: "anthropic", artifactBasename: "api" }),
  ];
}

type ReviewedProviderId = "anthropic" | "openai" | "google";
async function loadReviewedProviderDescriptor(providerId: ReviewedProviderId) {
  const { loadBundledPluginPublicSurfaceModule } = await import("./facade-loader.js");
  type Provider = import("../plugins/types.js").ProviderPlugin;
  const api = await loadBundledPluginPublicSurfaceModule<{
    buildAnthropicProvider?: () => Provider;
    buildOpenAIProvider?: () => Provider;
    buildGoogleProvider?: () => Provider;
  }>({ dirName: providerId, artifactBasename: "api" });
  const factory = {
    anthropic: api.buildAnthropicProvider,
    openai: api.buildOpenAIProvider,
    google: api.buildGoogleProvider,
  }[providerId];
  if (typeof factory !== "function") {
    throw new Error("Reviewed provider public factory is unavailable");
  }
  const provider = factory();
  if (provider.id !== providerId) {
    throw new Error("Reviewed provider public factory identity differs");
  }
  return provider;
}

/** Prepare shipped provider metadata for an explicit scope without registry discovery. */
export async function createBundledProviderRuntimeScopeMetadata(
  config: import("../config/types.openclaw.js").OpenClawConfig,
  providerId: "anthropic" | "openai" | "google",
): Promise<Omit<ExplicitProviderRuntimeScope, "config">> {
  if (providerId !== "anthropic" && providerId !== "openai" && providerId !== "google") {
    throw new Error("Unsupported bundled provider scope");
  }
  const { assertExplicitProviderAdmission } = await import("../plugins/provider-runtime-scope.js");
  assertExplicitProviderAdmission(config, providerId);
  const { buildAdmittedProviderAuthLookupMaps } = await import("../secrets/provider-env-vars.js");
  const { loadBundledPluginPublicSurfaceManifest } = await import("./facade-loader.js");
  const [provider, manifest] = await Promise.all([
    loadReviewedProviderDescriptor(providerId),
    loadBundledPluginPublicSurfaceManifest({ dirName: providerId, artifactBasename: "api" }),
  ]);
  // Both artifacts come from the existing bundled facade owner; the canonical
  // manifest loader performs the same normalization used by ordinary discovery.
  if (!manifest.providers?.includes(providerId)) {
    throw new Error("Bundled public surface manifest does not own the reviewed provider");
  }
  const providerManifest = { ...manifest, providers: manifest.providers };
  const authManifest = {
    ...manifest,
    providers: manifest.providers,
    origin: "bundled" as const,
    cliBackends: manifest.cliBackends ?? [],
  };
  return {
    provider,
    manifestPlugins: [
      {
        modelIdNormalization:
          "modelIdNormalization" in manifest ? manifest.modelIdNormalization : undefined,
      },
    ],
    providerManifest,
    authLookupMaps: buildAdmittedProviderAuthLookupMaps({ providerId, manifests: [authManifest] }),
  };
}

/** Read and core-validate source settings without loading unrelated plugin defaults. */
export async function loadValidatedSourceConfigForProvider() {
  const [{ readSourceConfigStrict }, { validateConfigObjectRaw }] = await Promise.all([
    import("../config/io.js"),
    import("../config/validation.js"),
  ]);
  const config = await readSourceConfigStrict();
  const validated = validateConfigObjectRaw(config);
  if (!validated.ok || Object.keys(validated.config).length === 0) {
    throw new Error("Source configuration failed core validation");
  }
  return validated.config;
}
