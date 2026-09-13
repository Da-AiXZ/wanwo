---
name: hello-wanwo
description: Show how WanWo skills work with a friendly onboarding walkthrough.
metadata:
  short-description: WanWo 技能入门示例
---

# Hello WanWo

1. Greet the user and briefly explain the three-tier progressive disclosure
   model: catalog (name + description, always visible with budget) → this
   SKILL.md body (loaded on trigger) → resources (never preloaded, fetched
   on demand by path).
2. Point the user to the `skill` tool and the `$hello-wanwo` explicit trigger
   as the two ways to reach a skill.
3. Suggest adding their own skill under the workspace `/.agents/skills/`
   directory (a `<name>/SKILL.md` bundle or a flat `<name>.md` file).
