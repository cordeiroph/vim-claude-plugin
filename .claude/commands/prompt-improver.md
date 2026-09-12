# prompt-improver

Prompt quality pre-processor. Take the following raw prompt and rewrite it into an optimized, high-quality prompt that will produce the best possible results when executed by Claude Code. Do NOT execute the task described in the prompt. Output only the improved prompt text.

## Raw Prompt

$ARGUMENTS

## Workflow

Follow these steps:

1. **Receive the raw prompt.** Read the user's original prompt carefully and identify its intent, target files, and desired outcome.

2. **Clarify ambiguities before rewriting.** If the prompt is ambiguous, has multiple possible interpretations, or is missing critical information needed to write a good prompt, ask the user ONE question at a time. Prefer multiple-choice questions to reduce friction. For example:
   - "Which module are you referring to? (a) src/auth/login.ts (b) src/auth/oauth.ts (c) something else"
   - "What should happen when the input is null? (a) throw an error (b) return an empty array (c) skip silently"
   Only proceed to rewriting once you have enough clarity. Do not guess when asking would produce a better result.

3. **Gather codebase context.** If the prompt references files, functions, classes, modules, or patterns — even vaguely — use Glob, Grep, and Read to locate the actual file paths, function signatures, class names, and relevant code structures. This grounds the rewritten prompt in real, specific references rather than guesses.

4. **Analyze the prompt for weaknesses.** Evaluate the raw prompt against these dimensions:
   - **Clarity:** Is the intent unambiguous? Are there multiple possible interpretations?
   - **Specificity:** Does it reference exact file paths, function names, line ranges, or class names? Or does it use vague references like "the auth file" or "that function"?
   - **Context:** Does it explain WHY the change is needed, not just WHAT to do?
   - **Actionability:** Are the steps concrete and ordered? Could someone execute them without further clarification?
   - **Constraints:** Are there explicit boundaries (what NOT to change, what to preserve, scope limits)?
   - **Output expectations:** Does it specify expected behavior, output format, or acceptance criteria?

5. **Rewrite the prompt** applying all of the following best practices:
   - Replace vague file references with absolute file paths discovered via Glob/Grep.
   - Replace vague function/class references with exact names and signatures discovered via Read.
   - Add the "why" — include context about the goal or motivation if missing.
   - Break complex requests into clear, numbered steps in logical order.
   - Use imperative, action-oriented language: "Read X, then modify Y to do Z."
   - Replace vague qualifiers ("make it better", "fix it", "clean up") with measurable outcomes ("reduce function to under 20 lines", "handle the null case by returning an empty array", "extract repeated logic into a shared utility").
   - Add explicit constraints: "Do not modify the public API surface", "Only change files in the /src/auth/ directory", etc.
   - Reference existing code patterns when the codebase already has conventions the task should follow.
   - Include acceptance criteria for substantial tasks: what does "done" look like?
   - Specify expected output format or behavior when relevant.

6. **Validate the rewrite.** Before outputting, verify:
   - Every file path mentioned actually exists in the codebase.
   - Every function/class name mentioned is real and correctly spelled.
   - The rewritten prompt preserves the full intent of the original — nothing is lost or added beyond what the user meant.
   - The rewritten prompt is self-contained: it can be understood and executed without the original prompt.

7. **Output the improved prompt.** Do not include commentary, explanations, before/after comparisons, or metadata. The output must be the improved prompt text — ready to be used directly as a new user message.

8. **Ask to proceed or revise.** After outputting the improved prompt, ask the user: "Would you like to (a) proceed with this prompt, (b) make changes, or (c) start over?" Wait for their response before taking any action. If they choose to make changes, apply their feedback and repeat from step 6. If they choose to proceed, execute the improved prompt as a new instruction.

## Response Format

Output the rewritten prompt, then on a new line ask the user whether they want to proceed, make changes, or start over. No preamble before the prompt itself.
