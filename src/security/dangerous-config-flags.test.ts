import { beforeEach, describe, expect, it, vi } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { collectEnabledInsecureOrDangerousFlags } from "./dangerous-config-flags.js";

const { loadPluginManifestRegistryMock } = vi.hoisted(() => ({
  loadPluginManifestRegistryMock: vi.fn(),
}));

vi.mock("../plugins/manifest-registry.js", () => ({
  loadPluginManifestRegistry: loadPluginManifestRegistryMock,
}));

function asConfig(value: unknown): OpenClawConfig {
  return value as OpenClawConfig;
}

describe("collectEnabledInsecureOrDangerousFlags", () => {
  beforeEach(() => {
    loadPluginManifestRegistryMock.mockReset();
  });

  it("collects manifest-declared dangerous plugin config values", () => {
    loadPluginManifestRegistryMock.mockReturnValue({
      plugins: [
        {
          id: "acpx",
          configContracts: {
            dangerousFlags: [{ path: "permissionMode", equals: "approve-all" }],
          },
        },
      ],
      diagnostics: [],
    });

    expect(
      collectEnabledInsecureOrDangerousFlags(
        asConfig({
          plugins: {
            entries: {
              acpx: {
                config: {
                  permissionMode: "approve-all",
                },
              },
            },
          },
        }),
      ),
    ).toContain("plugins.entries.acpx.config.permissionMode=approve-all");
  });

  it("collects sandbox no-new-privileges dangerous flags", () => {
    loadPluginManifestRegistryMock.mockReturnValue({
      plugins: [],
      diagnostics: [],
    });

    expect(
      collectEnabledInsecureOrDangerousFlags(
        asConfig({
          agents: {
            defaults: {
              sandbox: {
                docker: {
                  dangerouslyDisableNoNewPrivileges: true,
                },
              },
            },
            list: [
              {
                id: "sudo-agent",
                sandbox: {
                  docker: {
                    dangerouslyDisableNoNewPrivileges: true,
                  },
                },
              },
            ],
          },
        }),
      ),
    ).toEqual(
      expect.arrayContaining([
        "agents.defaults.sandbox.docker.dangerouslyDisableNoNewPrivileges=true",
        "agents.list.sudo-agent.sandbox.docker.dangerouslyDisableNoNewPrivileges=true",
      ]),
    );
  });

  it("ignores plugin config values that are not declared as dangerous", () => {
    loadPluginManifestRegistryMock.mockReturnValue({
      plugins: [
        {
          id: "other",
          configContracts: {
            dangerousFlags: [{ path: "mode", equals: "danger" }],
          },
        },
      ],
      diagnostics: [],
    });

    expect(
      collectEnabledInsecureOrDangerousFlags(
        asConfig({
          plugins: {
            entries: {
              other: {
                config: {
                  mode: "safe",
                },
              },
            },
          },
        }),
      ),
    ).toEqual([]);
  });
});
