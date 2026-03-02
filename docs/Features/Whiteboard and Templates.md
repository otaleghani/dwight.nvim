---
title: Whiteboard & Templates
description: Scratchpad for AI brainstorming and reusable prompt templates.
---
# Whiteboard & Templates

The whiteboard is a scratchpad for thinking with AI. Templates let you save and reuse prompts.

---

## Whiteboard

```vim
:DwightWhiteboard
```

Opens a scratch buffer where you can brainstorm with AI. Unlike `:DwightAgent` which executes tasks, the whiteboard is for exploration — asking questions, sketching ideas, working through design decisions.

The whiteboard buffer is a regular Neovim buffer with markdown filetype. You can write freely, and Dwight operations run from within it have the whiteboard content as additional context.

### Saving Brainstorms
Save the whiteboard contents for later reference:

```vim
:DwightWhiteboardSave                " Save entire buffer
:DwightWhiteboardSave api-design     " Save with a specific name
:'<,'>DwightWhiteboardSave           " Save visual selection only
```

Brainstorms are saved to `~/.dwight/brainstorm/` with a timestamp and optional name.

### Browsing Past Brainstorms
```vim
:DwightBrainstorms
```

Opens a Telescope picker (or fallback list) of all saved brainstorms. Select one to open it in a buffer.

---

## Templates

Templates are reusable prompt snippets. Save prompts you use frequently and recall them later.

### Saving a Template
```vim
:DwightSaveTemplate
```

Enter the prompt text when prompted. The template is saved to `.dwight/templates/` with a name you provide.

You can also save with the prompt inline:
```vim
:DwightSaveTemplate Refactor this to use dependency injection
```

### Using a Template
```vim
:DwightTemplate
```

Opens a picker of all saved templates. Selecting one copies the prompt to your clipboard, ready to paste into `:DwightAgent`, `:DwightAuto`, or any other command.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightWhiteboard` | | Open the brainstorming scratchpad |
| `:DwightWhiteboardSave` | `[name]` | Save whiteboard (supports visual range) |
| `:DwightBrainstorms` | | Browse saved brainstorm sessions |
| `:DwightTemplate` | | Pick a saved template (copies to clipboard) |
| `:DwightSaveTemplate` | `[prompt]` | Save a reusable prompt template |
