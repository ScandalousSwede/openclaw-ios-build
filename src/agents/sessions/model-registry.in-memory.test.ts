import { expect, it, vi } from "vitest";
import { resolveModelPluginMetadataSnapshot } from "../model-discovery-context.js";
import { AuthStorage } from "./auth-storage.js";
import { ModelRegistry } from "./model-registry.js";
vi.mock("../model-discovery-context.js", () => ({
  resolveModelPluginMetadataSnapshot: vi.fn(() => {
    throw new Error("unrelated discovery attempted");
  }),
}));
it("in-memory registry never resolves runtime configuration or plugin metadata", () => {
  const registry = ModelRegistry.inMemory(AuthStorage.inMemory());
  expect(registry.getAll()).toEqual([]);
  registry.refresh();
  expect(registry.getAll()).toEqual([]);
  expect(resolveModelPluginMetadataSnapshot).not.toHaveBeenCalled();
});
it("disk-backed registry retains metadata resolution", () => {
  expect(() => ModelRegistry.create(AuthStorage.inMemory(), "/synthetic/models.json")).toThrow(
    "unrelated discovery attempted",
  );
});
