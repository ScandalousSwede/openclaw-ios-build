import { AsyncLocalStorage } from "node:async_hooks";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import { normalizePluginsConfig } from "./config-state.js";
import { passesManifestOwnerBasePolicy } from "./manifest-owner-policy.js";
import type { ProviderPlugin } from "./types.js";

export type ExplicitProviderRuntimeScope = {
  config: OpenClawConfig;
  provider: ProviderPlugin;
  manifestPlugins?: readonly Pick<
    import("./manifest-registry.js").PluginManifestRecord,
    "modelIdNormalization"
  >[];
  providerManifest?: Pick<
    import("./manifest-registry.js").PluginManifestRecord,
    "id" | "providers" | "modelCatalog"
  > &
    Record<string, unknown>;
  authLookupMaps?: import("../secrets/provider-env-vars.js").ProviderAuthLookupMaps;
};
const scopes = new AsyncLocalStorage<Readonly<ExplicitProviderRuntimeScope>>();

/** Same pure base policy used by bundled provider owner activation. */
export function assertExplicitProviderAdmission(config: OpenClawConfig, pluginId: string): void {
  if (
    !passesManifestOwnerBasePolicy({
      plugin: { id: pluginId },
      normalizedConfig: normalizePluginsConfig(config.plugins),
    })
  ) {
    throw new Error("Provider plugin is disabled or denied by configuration");
  }
}

function immutableCopy<T>(value: T, seen = new WeakMap<object, unknown>()): T {
  if (!value || typeof value !== "object") return value;
  const prior = seen.get(value as object);
  if (prior) return prior as T;
  if (
    Object.getPrototypeOf(value) !== Object.prototype &&
    Object.getPrototypeOf(value) !== null &&
    !Array.isArray(value)
  ) {
    throw new Error("Unsupported mutable object in explicit provider scope");
  }
  const copy: Record<string, unknown> | unknown[] = Array.isArray(value) ? [] : {};
  seen.set(value as object, copy);
  for (const [key, child] of Object.entries(value)) {
    Object.defineProperty(copy, key, {
      value: immutableCopy(child, seen),
      enumerable: true,
      configurable: true,
      writable: true,
    });
  }
  return Object.freeze(copy) as T;
}

/** Snapshot caller-owned metadata; provider callbacks receive only the admitted immutable copy. */
export function withExplicitProviderRuntimeScope<T>(
  scope: ExplicitProviderRuntimeScope,
  run: (admitted: Readonly<ExplicitProviderRuntimeScope>) => T,
): T {
  if (!scope.config || !scope.provider.id?.trim() || scopes.getStore()) {
    throw new Error("Invalid or nested explicit provider runtime scope");
  }
  const admitted = immutableCopy(scope);
  assertExplicitProviderAdmission(admitted.config, admitted.provider.id);
  if (
    admitted.providerManifest &&
    (admitted.providerManifest.id !== admitted.provider.id ||
      !admitted.providerManifest.providers?.includes(admitted.provider.id))
  ) {
    throw new Error("Manifest does not own the admitted provider");
  }
  return scopes.run(admitted, () => run(admitted));
}

export function getExplicitProviderRuntimeScope() {
  return scopes.getStore();
}

export function resolveExplicitScopedProvider(params: {
  config?: OpenClawConfig;
  provider: string;
}): ProviderPlugin | undefined {
  const scope = scopes.getStore();
  if (!scope) return undefined;
  const names = [
    scope.provider.id,
    ...(scope.provider.aliases ?? []),
    ...(scope.provider.hookAliases ?? []),
  ];
  if (
    params.config !== scope.config ||
    !names.some((name) => name.trim().toLowerCase() === params.provider.trim().toLowerCase())
  ) {
    throw new Error("Provider lookup is outside the explicit runtime scope");
  }
  return scope.provider;
}

/** A closed provider invocation may not silently fall back to global discovery. */
export function assertProviderDiscoveryOutsideExplicitScope(): void {
  if (scopes.getStore())
    throw new Error("Provider metadata discovery is unavailable inside explicit runtime scope");
}
