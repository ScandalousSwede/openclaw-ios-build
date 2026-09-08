import { vi, type TestContext } from "vitest";
import type { PluginApprovalRequestPayload } from "../../infra/plugin-approvals.js";
import { createTestApprovalManager } from "../exec-approval-manager.test-support.js";
import type { GatewayRequestHandlerOptions } from "./types.js";
export function createManager(testContext: TestContext) {
  return createTestApprovalManager<PluginApprovalRequestPayload>(testContext, {
    approvalKind: "plugin",
  });
}

function createLogGatewayMock() {
  return { error: vi.fn(), warn: vi.fn(), info: vi.fn(), debug: vi.fn() };
}

export function createApprovalContext(
  params: {
    broadcast?: ReturnType<typeof vi.fn>;
    hasExecApprovalClients?: GatewayRequestHandlerOptions["context"]["hasExecApprovalClients"];
  } = {},
): GatewayRequestHandlerOptions["context"] {
  // SAFETY: This test-only fixture supplies the members used by approval handlers; production clients are never constructed here.
  return {
    getRuntimeConfig: () => ({}),
    broadcast: params.broadcast ?? vi.fn(),
    logGateway: createLogGatewayMock(),
    hasExecApprovalClients: params.hasExecApprovalClients ?? (() => true),
  } as unknown as GatewayRequestHandlerOptions["context"];
}

export function createClient(
  params: {
    connId?: string;
    clientId?: string;
    displayName?: string;
    deviceId?: string;
    scopes?: string[];
    approvalRuntime?: boolean;
  } = {},
): GatewayRequestHandlerOptions["client"] {
  const connect: Record<string, unknown> = {
    client: {
      id: params.clientId ?? "test-client",
      displayName: params.displayName ?? "Test Client",
    },
  };
  if (params.deviceId) {
    connect.device = { id: params.deviceId };
  }
  if (params.scopes) {
    connect.scopes = params.scopes;
  }
  // SAFETY: This test-only fixture supplies the members used by approval handlers; production clients are never constructed here.
  return {
    connId: params.connId ?? "conn-test-client",
    connect,
    ...(params.approvalRuntime ? { internal: { approvalRuntime: true } } : {}),
  } as unknown as GatewayRequestHandlerOptions["client"];
}

export function createMockOptions(
  method: string,
  params: Record<string, unknown>,
  overrides?: Partial<GatewayRequestHandlerOptions>,
): GatewayRequestHandlerOptions {
  // SAFETY: This test-only fixture supplies the members used by approval handlers; production clients are never constructed here.
  return {
    req: { method, params, id: "req-1" },
    params,
    client: createClient(),
    isWebchatConnect: () => false,
    respond: vi.fn(),
    context: createApprovalContext(),
    ...overrides,
  } as unknown as GatewayRequestHandlerOptions;
}
