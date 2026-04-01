import { describe, expect, it } from "vitest";
import { resolveSkillsPromptForRun } from "./skills.js";
import { createCanonicalFixtureSkill } from "./skills.test-helpers.js";
import type { SkillEntry } from "./skills/types.js";

describe("resolveSkillsPromptForRun", () => {
  it("prefers snapshot prompt when available", () => {
    const prompt = resolveSkillsPromptForRun({
      skillsSnapshot: { prompt: "SNAPSHOT", skills: [] },
      workspaceDir: "/tmp/openclaw",
    });
    expect(prompt).toBe("SNAPSHOT");
  });

  it("rewrites snapshot prompt locations when a sandbox path alias applies", () => {
    const prompt = resolveSkillsPromptForRun({
      skillsSnapshot: {
        prompt:
          "<available_skills>\n  <skill>\n    <location>/home/node/.openclaw/shared/skills/docker-deploy/SKILL.md</location>\n  </skill>\n</available_skills>",
        skills: [],
      },
      config: {
        agents: {
          defaults: {
            sandbox: {
              mode: "all",
            },
          },
        },
        skills: {
          load: {
            promptPathAliases: [
              {
                from: "/home/node/.openclaw/shared/skills",
                to: "/shared/skills",
                when: "sandbox",
              },
            ],
          },
        },
      },
      sessionKey: "agent:main",
      workspaceDir: "/tmp/openclaw",
    });

    expect(prompt).toContain("/shared/skills/docker-deploy/SKILL.md");
    expect(prompt).not.toContain("/home/node/.openclaw/shared/skills/docker-deploy/SKILL.md");
  });

  it("builds prompt from entries when snapshot is missing", () => {
    const entry: SkillEntry = {
      skill: createFixtureSkill({
        name: "demo-skill",
        description: "Demo",
        filePath: "/app/skills/demo-skill/SKILL.md",
        baseDir: "/app/skills/demo-skill",
        source: "openclaw-bundled",
      }),
      frontmatter: {},
    };
    const prompt = resolveSkillsPromptForRun({
      entries: [entry],
      workspaceDir: "/tmp/openclaw",
    });
    expect(prompt).toContain("<available_skills>");
    expect(prompt).toContain("/app/skills/demo-skill/SKILL.md");
  });
});

function createFixtureSkill(params: {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  source: string;
}): SkillEntry["skill"] {
  return createCanonicalFixtureSkill(params);
}
