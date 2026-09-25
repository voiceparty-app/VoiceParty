# `voiceparty-profile.json` (schema version 1)

The portable backup / sync file. Written by Settings → Backup & Sync → Export, read by Import
(which merges: nothing is deleted). Dates are ISO-8601; ids are UUID strings.

```jsonc
{
  "schemaVersion": 1,
  "app": "VoiceParty",
  "exportedAt": "2026-09-24T18:00:00Z",
  "dictionary": [
    { "id": "…", "phrase": "Tamaro", "replacement": null, "source": "manual|learned|imported",
      "isStarred": true, "createdAt": "…", "useCount": 3, "lastUsedAt": "…" },
    { "id": "…", "phrase": "btw", "replacement": "by the way", … }
  ],
  "snippets": [
    { "id": "…", "trigger": "my calendar link", "expansion": "https://…", "createdAt": "…", "useCount": 0 }
  ],
  "transforms": [
    { "id": "…", "kind": "polish|promptEngineer|custom", "name": "Polish", "summary": "…",
      "instructions": "…", "rules": { "concise": true, … }, "slot": 1 }
  ],
  "settings": { … AppSettings, see Sources/VoicePartyCore/Models/AppSettings.swift … }
}
```

Merge rules:
- Dictionary entries match on `phrase` (case-insensitive). An incoming replacement or star is applied;
  the entry keeps its local id.
- Snippets match on the trigger with case and punctuation ignored; the incoming expansion wins.
- Only `custom` transforms are imported; built-ins stay local. A clashing ⌥ slot is cleared.
- Shortcuts are only exported/imported when "Include shortcuts" is on (keyboards differ between Macs).
- Unknown keys are ignored and missing keys take defaults, so older and newer files both load.
  A file with a higher `schemaVersion` is rejected with a message to update.

Bulk import:
- Dictionary CSV: one entry per line, `phrase` or `phrase,replacement` (quotes allowed).
- Snippets JSON: `[{"name": "trigger", "text": "expansion"}]`.
