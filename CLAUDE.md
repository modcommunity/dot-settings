# dot-settings

Settings as a bounded document, with three scopes and a server that may clamp but never read.

**The distributable is `addons/dot_settings/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists

Every game in this family has a `DotConfig` and none of them has anywhere to put a *player's* settings. A `DotConfig` is a deployment's configuration: layered from defaults, a file, the environment and argv, loaded at boot and not written back. A volume slider is none of those things — it changes at runtime, it belongs to a person rather than to a process, and it has to survive a crash.

`DotSettingsConfig` is the bridge and it is the interesting part of the addon: a `DotConfig` whose properties are a schema's keys, built at runtime. dot-ui generates a settings panel from any `DotConfig` by reflection, so handing one over means **a new setting appears on a screen with nobody editing a screen** — and this addon still does not know a `Control` exists.

The mechanism matters, because the obvious spelling does not work: **Godot refuses a dynamic property on an `Object`**. Assigning `cfg.some_new_key = 1` pushes an error and sets nothing, which this family shipped once — a game descriptor whose `module` was assigned that way named no module at all, and the failure was a scene with nothing behind it. `_get_property_list` / `_get` / `_set` is the supported way, and the properties are then real to every reflective caller, including `DotConfig`'s own `config_keys()`.

## What building it found, and it is the most important entry here

**`!=` between two mismatched Variant types is a runtime ERROR in GDScript, not `true`.** `coerce_document` compared a coerced int with the String it came from, the expression was abandoned, and the section aborted — **while the suite reported "8 sections, 63 passed, 0 failed" and exited 0.**

Two things came out of that:

1. **`DotValue` is now in dot-core**, with a self-test. dot-npc-ai's blackboard had this exact bug (`get_value(...) != MISSING` answered false for every value that was not a `StringName`), so it is the second time, and the class is the family's answer. Use it anywhere either side is a `Variant` whose type you do not control.
2. **Every suite here now asserts a CHECKS total, not just a section count.** The section counter cannot catch this: the section had already announced itself before it aborted. A total can, and it is one line. dot-console, dot-audio, dot-fx, dot-procedural-generation, dot-inventory, dot-peer-to-peer and dot-randomness all gained one.

The related one, smaller: a value that changed only its Variant type is **not** a correction worth telling a player about. `fov: 110 -> 110` is noise, and noise is what stops the real lines being read. The comparison there is on what they print, which is exactly the question being asked.

## The three scopes

`DEVICE` never synchronises — a synchronised resolution breaks itself every time a player switches machines. `ACCOUNT` lives under `shared_namespace`, as a **second document rather than a merged one**, so two games opting into one name share a sensitivity and a game that does not opt in is unaffected by either. `SERVER_CLAMPED` is the small set a server may cap.

The account half is read **after** the local half on load, so it wins for the keys it owns. Reading it first would let a stale local copy overwrite the shared one, which is the direction that loses the change a player just made on another machine.

## A server may clamp and may never read

There is no read direction in this addon. Capping field of view is a legitimate competitive rule; asking a client for its bindings, its audio device or its resolution is a fingerprint that survives a new account and every ban a moderator issues. `apply_server_clamps` returns which keys it accepted and sends nothing back.

**A clamp is a bound, not a value.** `get_value` is capped, `chosen_value` is the player's own, and `to_document` writes the choice. Every game that gets this wrong gets it wrong in the same direction, and the symptom is a setting that resets itself on every join.

`clamps_persist` defaults to false, and that is not a preference: a persisting clamp is a server permanently editing the settings of somebody who has left, with no way for them to tell which of their values came from a server they played on once.

## Unknown keys are kept

The downgrade path. A player who runs a newer build, changes a setting it added and goes back would otherwise lose it silently, and lose it again every time. They survive a `reset_all` too, because they belong to a build this one does not know about and throwing them away is destroying somebody else's settings on their behalf.

## The pieces

| | |
| --- | --- |
| `DotSettingsDef` | One setting: kind, scope, bounds, and the coercion. |
| `DotSettingsSchema` | All of them, a version, and the migrations. The only list. |
| `DotSettingsConfig` | A `DotConfig` built from a schema at runtime. The dot-ui bridge. |
| `DotSettingsPolicy` | What a server may touch. A `DotConfig` itself. |
| `DotSettingsStore` | Three methods. A missing document is a success, not a failure. |
| `DotSettingsStoreFile` | Atomic JSON under `user://`, flushed for the web. |
| `DotSettingsStoreMemory` | A suite's, and the honest fallback for a refused storage quota. |
| `DotSettingsManager` | The node a game holds. |

## Decisions

### A missing document is a success

"Nobody has ever saved settings here" is the first run of every installation. A store that reports it as an error makes every caller write the same two-line special case, and that is the case somebody gets wrong — and then a first run is a crash.

### Coercion corrects, and refuses only what is not the setting

A settings file is edited by hand more often than any other file in a game. Refusing the whole document because one slider is out of range is a player who lost every other setting they had. The exception is an enum: an unknown option is refused outright, because silently substituting the default means a renamed option puts everybody back to "low" with nothing said.

### `_clamp_number` returns a `Variant`

Its two branches genuinely return different types, and declaring it `int` silently truncates every float setting in the schema — a volume slider that can only be 0 or 1, with every property about it reading correctly.

### A corrupt file is renamed, not deleted

`.broken` beside it. The one thing worse than losing a settings file is losing it and being unable to show anybody what was in it.

### `app_namespace`, not `namespace`

`namespace` is a reserved word in GDScript, and the error it produces is *"Expected parameter name"* — which points at the punctuation rather than at the word.

## Things deliberately not here

- **An account store.** It is an HTTP client against somebody's backbone and whose backbone it is, is not this addon's decision. `remote_store` takes any subclass.
- **A settings screen.** dot-ui generates one from the `DotConfig`. Shipping a second would be two screens to keep in step.
- **Key binding storage beyond a string.** `Kind.BINDING` holds text and is opaque here. dot-ui has the rebinder and the conflict detection; this stores what it produces.
- **Cloud conflict resolution.** Two machines that both changed the same account setting while offline is a real problem and a bigger one than this; last-write-wins is what the shipped store does and the addon says so rather than pretending.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/settings_selftest.tscn
```

8 sections, 71 checks. **Read the stderr even when it exits 0** — this is the addon that proved why.
