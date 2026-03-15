---
title: Library References
description: Add structured API references for external libraries so the AI knows your dependencies' types, methods, and patterns.
---

# Library References

Library references are structured API descriptions stored in `.dwight/libs/`. When you reference a library with `%lib-name` in a prompt, Dwight injects its API signatures, types, and usage patterns into the AI's context.

---

## How It Works

1. **Add a library** — `:DwightAddLib` prompts for the library name and source (URLs or installed package).
2. **Generation** — Dwight fetches documentation or reads type definitions and generates a compact XML reference.
3. **Use in prompts** — type `%htmx` or `%zod` in any prompt buffer to inject the reference.

```vim
:DwightAddLib                " Interactive: name, source (URLs or "source")
:DwightLibs                  " Browse existing library references
```

---

## Adding Libraries

### From Documentation URLs

Provide one or more URLs to the library's documentation. Dwight fetches the pages, extracts the text (max 25K characters), and generates an XML reference with API signatures, types, and usage patterns.

### From Installed Packages

Enter `source` instead of URLs. Dwight searches for type definitions:
- **Node.js** — reads `.d.ts` files from `node_modules/@types/` or the package's own types
- **Python** — reads `.pyi` stub files from the installed package

The type definitions are sent to the AI to produce a structured reference.

---

## XML Format

Library references use XML for precise, structured LLM consumption:

```xml
<library name="htmx" source="https://htmx.org/reference/">
  <description>HTML-first AJAX library</description>
  <api>
    <function name="htmx.ajax" returns="Promise">
      <param name="verb" type="string" />
      <param name="url" type="string" />
      <description>Issue an AJAX request</description>
    </function>
    <class name="htmx.config">
      <property name="historyCacheSize" type="number" />
    </class>
  </api>
  <types>...</types>
  <patterns>...</patterns>
</library>
```

Legacy `.md` references are also supported — Dwight reads either format from `.dwight/libs/`.

---

## Using in Prompts

Reference libraries with the `%` prefix in any prompt buffer:

```
Rewrite this form handler using %zod for validation and %htmx for submissions
```

Multiple libraries can be referenced in a single prompt. Each library's content is injected into the context alongside your code selection and skills.

---

## Browsing Libraries

```vim
:DwightLibs
```

Opens a Telescope picker (or fallback list) of all library references with a preview of each reference's content.

---

## Generating from URLs

```vim
:DwightDocsFromURL
```

Similar to `:DwightAddLib` but generates a skill file (`.dwight/skills/`) instead of a library reference. Use this when you want the documentation to influence coding patterns rather than provide API signatures.

---

## Tips

- **Add references for your key dependencies.** If you use a library heavily, a reference file means the AI knows its API without guessing or hallucinating.
- **Use `%lib` in the prompt buffer.** The `%` prefix resolves at prompt build time, so the AI sees the full API reference alongside your code.
- **Prefer XML over markdown for API references.** XML gives the AI structured type information. Markdown is better for patterns and conventions (use skills for that).
- **Regenerate after major version upgrades.** API references can go stale — re-run `:DwightAddLib` when a library's API changes significantly.

---

## Commands

| Command | Args | Description |
|---------|------|-------------|
| `:DwightAddLib` | | Add a library API reference (interactive) |
| `:DwightLibs` | | Browse library references |
| `:DwightDocsFromURL` | | Generate a skill from a documentation URL |

---

## See Also

- [[Skills and Marketplace]] -- skills guide coding patterns; libraries provide API signatures
- [[Inline Editing]] -- where `%lib-name` tokens are used in the prompt buffer
- [[Core Concepts]] -- how library references fit into the context system
