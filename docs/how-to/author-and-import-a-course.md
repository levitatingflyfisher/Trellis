# How-to: author & import a course

Task-oriented: get an `.ohcourse` into Trellis. For the full format, see the
[format reference](../curriculum-format.md); for the ideas, [concepts](../concepts.md).

## Get a course file

You have three options:

1. **Use the bundled one.** A Kalman-filter / multi-target-tracking course ships in
   `assets/courses/` and is there on first launch — nothing to do.
2. **Author one with the `trellis-author` skill** (external). Give it a source (paste
   a transcript/paper/chapter) or just a topic ("build me a Trellis course on X"); it
   researches, builds the concept graph + intake passages + recall ladder, validates
   against the schema, and writes a `.ohcourse` file.
3. **Write one by hand** to the [format spec](../curriculum-format.md). Validate it
   against `schema/ohcourse.schema.json` before importing.

## Import it into the app

1. On the **Library** screen, tap the **+** (Import a .ohcourse) button.
2. **Paste the `.ohcourse` JSON** into the dialog and tap **Import**.
3. On success the course appears in your library. On failure the app shows a
   **path-qualified error** telling you exactly which node/item/field is wrong (e.g.
   `node 'kf-core' item 'kf-1': cloze requires 'text' and 'answers'`) — fix it and
   re-import. Import is all-or-nothing: a malformed file never half-loads.

An imported course with the same `id` as a bundled one overrides the bundled version.

## What makes a valid course (the checks that run on import)

- `schemaVersion` must be exactly `"1.0"`.
- `id`, `title`, and a non-empty `nodes` list are required; each node needs `id`,
  `title`, `intake`, and a non-empty `items` list.
- Every `prereq` must reference a real node; no node may list itself; the
  prerequisite graph must be **acyclic**.
- Each item's `type` must be one of `cloze`, `qa`, `discrimination`, `procedure`, with
  that type's required fields present (e.g. `cloze` needs `text` + non-empty
  `answers`; `discrimination` needs an in-range `correctIndex`).

If in doubt, validate against the JSON Schema first — the app enforces the same rules
and will reject anything that doesn't pass.
