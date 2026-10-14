vim.opt.rtp:prepend("/home/toast/opencode-nvim")

require("opencode-nvim").setup({
  server = { command = "opencode", autostart = true },
  agent = "build", -- agente padrão
  model = { providerID = "opencode-go", id = "deepseek-v4.1-flash" },
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
        info = "Investigate the repo and draft a planning/execution document under tasks/",
        text = [==[
Transform the task provided at the end of this prompt into a detailed technical planning and execution document, following the structure and level of detail of the reference document. The document should cover the objective, current repository state, implementation plan, technical specifications, business rules, edge cases, acceptance criteria, and architectural decisions.

## 1. Repository Preparation

Before writing the document:

1. Identify the root directory of the current repository.
2. Check whether a `tasks/` directory exists at the repository root.
3. If it does not exist, create it.
4. Inspect the root `.gitignore`. Add `tasks/` if it is not already present, preserving all existing rules and avoiding duplicate entries. Do not overwrite the file.
5. Inspect the project structure, technologies, modules, and files relevant to the task.

The entire `tasks/` directory must be ignored by Git, as these documents are local planning and execution artifacts.

## 2. Technical Investigation

Do not write a generic document based solely on the task description. Investigate the existing codebase before defining the plan.

- Identify relevant components, services, models, endpoints, routes, screens, configurations, and tests.
- Determine how the affected functionality currently works.
- Identify limitations, dependencies, existing behavior, and potential impacts on other parts of the system.
- Use actual file paths, function names, structs, classes, database tables, and endpoints found in the repository.
- Clearly distinguish facts confirmed by the codebase from proposed implementation details.
- Never invent files, functions, endpoints, behaviors, or requirements.
- If a detail cannot be verified, document the uncertainty instead of presenting it as a fact.
- Read relevant files thoroughly enough to understand their behavior. Do not rely exclusively on filenames or text search results.

## 3. Clarification Before Planning

**Before creating or writing the Markdown document, review the task description and the repository to identify ambiguities, missing requirements, conflicting instructions, and decisions that could materially affect the implementation.**

If clarification is needed, ask me questions before proceeding.

Follow these rules:

1. Ask about requirements that are missing, unclear, contradictory, or open to multiple reasonable interpretations.
2. Prioritize questions that could change the architecture, data model, API contracts, user experience, security, business rules, scope, or implementation sequence.
3. Do not ask questions that can be answered reliably by inspecting the repository.
4. Do not ask about minor implementation details that can reasonably be decided by following existing project conventions.
5. Group related questions into a single message when practical. Keep each question specific and explain the relevant alternatives briefly when that helps me decide.
6. If a decision has a sensible default, propose that default and ask me to confirm it when the decision is important.
7. If the task is already sufficiently specified, do not ask unnecessary questions. Proceed directly.
8. If I answer only some questions, use the answers provided and ask follow-up questions only for remaining critical ambiguities.
9. Do not create the final task document until the necessary clarifications have been resolved.
10. Do not treat silence or an unanswered question as confirmation of an assumption. If a noncritical detail remains unresolved, document the assumption explicitly in the final plan.

You may inspect the repository before asking questions, but do not implement the requested feature. If clarification is required, stop after asking your questions and wait for my response.

## 4. Document Structure

Once the requirements are sufficiently clear, create a Markdown document containing the following sections, adapting them to the nature and complexity of the task.

### Task Title
A short, specific, descriptive title.

### Objective
Explain the problem to be solved, the expected outcome, and the desired finalbehavior.

### Naming Conventions and Decisions
Document domain terminology, naming conventions, important distinctions, and implementation conventions that must be respected. Include this section when relevant.

### Current State
Describe how the system works today, referencing actual files and components, existing limitations, and why the change is necessary.

### Implementation Plan
Divide the implementation into sequential, independently verifiable stages with clear deliverables.

For each stage, specify:
- Objective.
- Deliverables.
- Relevant files and components.
- Dependencies on previous stages.
- Verification criteria.
- Initial status: pending.

Use Markdown checkboxes to track progress:

- [ ] Stage 1 — Stage name
- [ ] Stage 2 — Stage name

Never mark a stage as completed before its implementation and verification have actually been performed.

Organize stages so that each can be implemented and validated independently whenever practical. Avoid grouping the entire task into one oversized stage.

### Functional and UI Specifications
When the task involves interface changes, describe screens, components, states, interactions, messages, navigation flows, responsive behavior, and expected user interactions.

When no UI is involved, replace this section with specifications appropriate to the task.

### Business Rules
Document the rules that must be preserved, mandatory validations, permissions, states, restrictions, and expected behavior.

### Technical Specifications
Describe the proposed changes by system layer, as applicable:

- Database, models, and migrations.
- Backend, services, handlers, and endpoints.
- Frontend, components, pages, stores, and routes.
- External integrations, authentication, and infrastructure.
- Automated tests and validation.

Use actual paths and identifiers discovered during the investigation. Explicitly distinguish the current implementation from the proposed solution.

### Edge Cases
List relevant failure scenarios, missing or invalid data, unexpected states, concurrency issues, backward compatibility, permissions, and potential regressions.

Include only cases relevant to the task.

### Acceptance Criteria
Create an objective, verifiable checklist of conditions that must be satisfied before the task can be considered complete.

Whenever possible, associate each criterion with a test, command, or observable behavior.

### Verification Commands
List actual, relevant commands for validating the implementation, based on the technologies and tools used in the repository. Do not assume a command exists without checking the project structure.

### Decisions Made
Record architectural or functional decisions explicitly established by the original task, confirmed during clarification, or verified during investigation.

If decisions remain unresolved, document assumptions and outstanding questions explicitly.

## 5. Document Quality

The document must provide enough detail for a coding agent to implement the task without having to reconstruct the entire project context.

Follow these rules:

- Be specific, technical, and concise.
- Preserve every explicit requirement from the original task.
- Incorporate all relevant decisions made during the clarification process.
- Do not remove requirements to simplify the plan.
- Do not present assumptions as confirmed requirements.
- Avoid unnecessary repetition across sections.
- Prefer small, sequential stages with measurable outcomes.
- Consider backward compatibility, security, data integrity, and regression prevention when applicable.
- Reference relevant files and explain their responsibilities.
- Use valid Markdown with a consistent heading hierarchy, lists, and checkboxes.
- Adapt the sections to the task. Do not fill irrelevant sections with artificial content.
- Do not expand the scope beyond what was requested without explicitly identifying the proposed addition and obtaining my approval when it materially changes the task.

## 6. File Naming and Destination

Save the document inside `tasks/` at the repository root.

Use a short `kebab-case` filename that describes the feature. Example: `tasks/multi-enterprise-accounts.md`.

Before creating the file, check whether a document with the same name already exists. If it does, do not silently overwrite it. Choose a distinct filename to prevent data loss, or update the existing document only when it clearly describes the same task and updating it is appropriate.

## 7. Execution Scope

Your responsibility is to investigate the repository, prepare the `tasks/` directory, update `.gitignore` if necessary, clarify requirements with me when needed, and create the Markdown document.

Do not implement the functionality described in the original task.

Do not modify application source files. The only permitted repository changes are:
- Adding `tasks/` to the root `.gitignore`, if necessary.
- Creating the task Markdown document inside `tasks/`.

If clarification is required, ask your questions and wait for my response before creating the document or making repository changes.

When finished, report:
- The path of the created document.
- A summary of the sections and implementation stages defined.
- Which files were created or modified.
- Any assumptions, unresolved questions, or details that could not be confirmed during the investigation.

Perform these actions directly in the repository. Do not return only a suggested document outline or its contents.

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
