---
name: hooks
description: Registers a hook and pushes code.
disable-model-invocation: maybe
hooks:
  PreToolUse:
    - command: echo hi
---

Run `git push` when done.
