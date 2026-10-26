vim.opt.rtp:prepend("/home/toast/opencode-nvim")

require("opencode-nvim").setup({
  server = { command = "opencode", autostart = true },
  agent = "build", -- agente padrão
  model = { providerID = "opencode-go", id = "deepseek-v1-flash" },
  approval = false,
  -- approval = {
  --   review = "popup",        -- "popup" | "notify"
  --   agent = "opencode-nvim", -- agente de pré-aprovação
  --   auto_detect = true,      -- usa qualquer agente que peça aprovação
  -- },
  reload = { enabled = true, set_autoread = true },
  context = {
    auto = true,
    max_bytes = 200 * 1024,
    placeholders = {
      {
        word = "@task",
        menu = "plan a task into tasks/<feature>.md",
        info = "Investigate the repo and draft a focused planning document under tasks/",
        text = [==[
Investigate the repository and write a focused planning document for the task at the end of this prompt. The goal is a document I can read quickly to understand the current state, what has to change, and the implementation stages. Favor bullets over prose and cut anything that doesn't help implement or review the task.

## 1. Setup

1. Identify the repository root.
2. Create `tasks/` there if it does not exist.
3. Add `tasks/` to the root `.gitignore` if missing, preserving existing rules and avoiding duplicates. Don't rewrite the file.
4. Save the document as `tasks/<short-kebab-case-name>.md`. If a file with that name already exists, don't overwrite it silently — pick another name, or update it only if it clearly describes the same task.

## 2. Investigation

Do not write a generic document from the task description alone. Investigate first.

- Read the files actually involved; don't rely on filenames or search hits.
- Use real paths, components, functions and identifiers found in the repo. Never invent files, endpoints or behavior.
- Separate facts confirmed by the code from proposed changes.
- If something can't be verified, record it as an open question instead of asserting it.
- Don't implement the feature or modify source files. The only allowed changes are the `.gitignore` entry and the new document.

## 3. Clarification

Ask me questions before writing the document only when an ambiguity could change architecture, data model, API contracts, scope or UX. Don't ask what the code or existing conventions already answer. If a decision has a sensible default, propose it and move on. If the task is clear enough, skip this step. Document any remaining assumption explicitly.

## 4. Document

Aim for roughly 100-150 lines. Adapt the sections to the task and drop any that don't apply.

Hard-wrap the Markdown at 120 characters per line: break long paragraphs, bullet items and prose into shorter lines instead of leaving one huge line, so the document reads well in a narrow editor. Keep code blocks and tables intact.

### Objective
The problem and the expected outcome, 2-4 sentences.

### Current state
How it works today, with the real files and components involved, plus the limitations that motivate the change.

### What needs to change
Concrete bullets grouped by file or area. Say what changes and why, not how to type it.

### Stages
Small sequential steps that can be verified independently. Use checkboxes, all pending:

- [ ] Stage 1 — name
- [ ] Stage 2 — name

For each stage list: objective, files touched, and how to verify it. Never mark a stage done before it is implemented and verified.

State explicitly in the document that execution is strictly one stage at a time: after finishing a stage, stop, report what changed and the verification result, and wait for my explicit go-ahead before starting the next one. Never continue on your own or batch several stages into one pass.

### Risks and edge cases
Only the ones that are real for this change (regressions, compatibility, data integrity). Skip the boilerplate.

### Verification
Actual commands that exist in this repo, one per stage where useful.

Add a short UI section only when the task involves visible interface changes, and a naming/decisions note only when terms or conventions need pinning down.

## 5. Report

When finished, tell me the document path, the stage list, which files were created or modified, and any assumptions or open questions.

---

## Task Description
]==],
      },
      {
        word = "@task-fast",
        menu = "do a task end to end, no document, no pausing",
        info = "Investigate, implement and verify the task in one pass, without a planning document",
        text = [==[
Investigate the repository and implement the task at the end of this prompt, end to end, in a single pass. Do not write a planning document and do not stop between steps for approval.

## 1. Setup

1. Identify the repository root.
2. Do not create or modify anything under `tasks/` and do not touch `.gitignore`; this is not a planning run.

## 2. Investigation

- Read the files actually involved; don't rely on filenames or search hits.
- Use real paths, components, functions and identifiers found in the repo. Never invent files, endpoints or behavior.
- Match the structure, naming, style and patterns of the surrounding code.
- Change only what the task needs; leave unrelated files and behavior alone.
- Before deleting or overwriting something that looks like unfinished user work, check what it is first.
- Ask me a question only when an ambiguity could change architecture, data model, API contracts, scope or UX. If a decision has a sensible default, take it, implement it and record the assumption for the report. Otherwise keep going without pausing.

## 3. Implementation

- Plan internally, then do the whole job: every file, every call site, every migration the task requires.
- Do not wait for a go-ahead, do not deliver "Stage 1" and stop, and do not ask me to confirm a plan that the code already answers.
- No stubs, placeholders, TODOs or omitted bodies. The result must be complete, coherent and usable when you finish.
- If you hit a real blocker, say what it is and finish everything that does not depend on it.

## 4. Verification

- Run the checks this repo actually has for the area you touched (tests, linters, formatters, builds) — check AGENTS.md and the README for the conventions there.
- Fix failures you introduced before finishing. Never claim something works without running it.

## 5. Report

When finished, tell me what changed (files, one line each), how it was verified (the commands run and their result), and any assumptions, trade-offs, open questions or parts left unverified.

---

## Task Description
]==],
      }
    }
  },
  ui = {
    panel = {
      width = 0.45,
      height = 0.50,
      max_width = 110,
      max_height = 50,
      tool_output = false
    },
    focus_after_submit = "panel",
  },
})
