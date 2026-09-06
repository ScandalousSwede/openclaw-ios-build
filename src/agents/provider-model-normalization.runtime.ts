/**
 * Runtime bridge for provider-owned model id normalization hooks. Source and
 * built artifacts can resolve different extensions, so this module probes both
 * once and caches the result.
 */
import { createRequire } from "node:module";
import { normalizeProviderModelIdWithManifest } from "../plugins/manifest-model-id-normalization.js";
import type { PluginManifestRecord } from "../plugins/manifest-registry.js";
import {
  getExplicitProviderRuntimeScope,
  resolveExplicitScopedProvider,
} from "../plugins/provider-runtime-scope.js";

type ProviderRuntimeModule = Pick<
  typeof import("../plugins/provider-runtime.js"),
  "normalizeProviderModelIdWithPlugin"
>;

const require = createRequire(import.meta.url);
// Built code loads .js while source/test paths may still resolve .ts. Try both
// once, then cache the absence to avoid repeated require work on hot paths.
const PROVIDER_RUNTIME_CANDIDATES = [
  "../plugins/provider-runtime.js",
  "../plugins/provider-runtime.ts",
] as const;

let providerRuntimeModule: ProviderRuntimeModule | undefined;
let providerRuntimeLoadAttempted = false;

function loadProviderRuntime(): ProviderRuntimeModule | null {
  if (providerRuntimeModule) {
    return providerRuntimeModule;
  }
  if (providerRuntimeLoadAttempted) {
    return null;
  }
  providerRuntimeLoadAttempted = true;
  for (const candidate of PROVIDER_RUNTIME_CANDIDATES) {
    try {
      providerRuntimeModule = require(candidate) as ProviderRuntimeModule;
      return providerRuntimeModule;
    } catch {
      // Try source/runtime candidates in order.
    }
  }
  return null;
}

/** Normalizes provider model ids through plugin runtime hooks when available. */
export function normalizeProviderModelIdWithRuntime(params: {
  provider: string;
  plugins?: readonly Pick<PluginManifestRecord, "modelIdNormalization">[];
  context: {
    provider: string;
    modelId: string;
  };
}): string | undefined {
  const scope = getExplicitProviderRuntimeScope();
  if (scope) {
    const provider = resolveExplicitScopedProvider({
      config: scope.config,
      provider: params.provider,
    })!;
    const normalized = provider.normalizeModelId?.(params.context);
    return (
      (typeof normalized === "string" && normalized.trim() ? normalized.trim() : undefined) ??
      normalizeProviderModelIdWithManifest(params)
    );
  }
  return loadProviderRuntime()?.normalizeProviderModelIdWithPlugin(params);
}
