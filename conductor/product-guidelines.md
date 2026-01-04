# Product Guidelines - cmm

## Tone and Voice
- **Professional & Empathetic:** The tool should use clear, reassuring language. It must acknowledge the inherent risk of system-level changes while remaining technically precise.
- **Tech-Savvy & Witty:** Maintenance can be a chore; a touch of personality and developer-focused humor (without being unprofessional) helps keep the experience engaging.
- **Transparency First:** Never hide what the tool is doing. If a command is complex, explain it briefly and clearly.

## Visual Design & Formatting
- **Semantic Coloring:** Colors must carry meaning.
    - `Red`: Destruction, danger, or errors.
    - `Yellow`: Warnings or items requiring caution.
    - `Green`: Success, safe checks, or completed tasks.
    - `Blue/Cyan`: Informational or guided context.
- **Visual Hierarchy:** Utilize bold headers, clear indentation, and whitespace to make the CLI output skimmable and well-organized.
- **Interactive TUI Elements:** Prioritize modern terminal elements:
    - Use spinners for long-running processes (e.g., scanning disk).
    - Use progress bars for multi-file operations.
    - Use interactive menus (arrow keys + space/enter) for selection flows.

## Safety & Error Prevention
- **High-Visibility Warnings:** Use distinct borders or inverted text styles for critical warnings that require the user's immediate attention.
- **Explicit Confirmation:** For high-risk operations (e.g., "Nuclear" cache clearing or Time Machine snapshot deletion), require the user to type an explicit keyword like `YES` or `DELETE`.
- **Contextual Education:** Every destructive action must be preceded by a brief explanation of the target and its impact (e.g., "Clearing Xcode Derived Data will force a rebuild of your current projects but will free up X GB").

## Messaging Guidelines
- **Success Messages:** Always report the outcome (e.g., "Successfully reclaimed 4.2 GB").
- **Error Handling:** Don't just show a stack trace. Explain *why* it failed (e.g., "Permission denied") and suggest a fix (e.g., "Try running with sudo").
