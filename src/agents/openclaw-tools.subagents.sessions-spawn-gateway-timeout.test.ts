import { beforeEach, describe, expect, it } from "vitest";
import "./test-helpers/fast-core-tools.js";
import * as sessionsHarness from "./openclaw-tools.subagents.sessions-spawn.test-harness.js";
import { resetSubagentRegistryForTests } from "./subagent-registry.js";

const MAIN_SESSION_KEY = "agent:test:main";

function applySubagentGatewayTimeoutDefault(timeoutMs: number) {
  sessionsHarness.setSessionsSpawnConfigOverride({
    session: { mainKey: "main", scope: "per-sender" },
    agents: { defaults: { subagents: { gatewayTimeoutMs: timeoutMs } } },
  });
}

function getGatewayCallTimeouts(
  calls: Array<{ method?: string; timeoutMs?: number }>,
  method: string,
): number[] {
  return calls
    .filter((call) => call.method === method)
    .map((call) => call.timeoutMs)
    .filter((timeoutMs): timeoutMs is number => typeof timeoutMs === "number");
}

async function spawnSubagent(callId: string, payload: Record<string, unknown>) {
  const tool = await sessionsHarness.getSessionsSpawnTool({ agentSessionKey: MAIN_SESSION_KEY });
  const result = await tool.execute(callId, payload);
  expect(result.details).toMatchObject({ status: "accepted" });
}

describe("sessions_spawn internal gateway timeout defaults", () => {
  beforeEach(() => {
    sessionsHarness.resetSessionsSpawnConfigOverride();
    resetSubagentRegistryForTests();
    sessionsHarness.getCallGatewayMock().mockClear();
  });

  it("uses configured gatewayTimeoutMs for internal sessions.patch and agent calls", async () => {
    applySubagentGatewayTimeoutDefault(30_000);
    const gateway = sessionsHarness.setupSessionsSpawnGatewayMock({});

    await spawnSubagent("call-timeout", { task: "hello" });

    expect(getGatewayCallTimeouts(gateway.calls, "sessions.patch")).toEqual([30_000, 30_000]);
    expect(getGatewayCallTimeouts(gateway.calls, "agent")).toEqual([30_000]);
  });
});
