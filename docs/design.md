# Design

Why dot-settings is shaped the way it is, and why the obvious alternative is wrong in each case.

## Why this exists

A `DotConfig` is a deployment's configuration: layered from defaults, a file, the environment and argv, loaded at boot and not written back. A volume slider is none of those things: it changes at runtime, it belongs to a person rather than to a process, and it has to survive a crash.

## `DotSettingsConfig`: a `DotConfig` built from a schema

`DotSettingsConfig` is the bridge and the interesting part of the addon: a `DotConfig` whose properties are a schema's keys, built at runtime. dot-ui generates a settings panel from any `DotConfig` by reflection, so handing one over means **a new setting appears on a screen with nobody editing a screen**, and this addon still does not know a `Control` exists.

The obvious spelling does not work: **Godot refuses a dynamic property on an `Object`**. Assigning `cfg.some_new_key = 1` pushes an error and sets nothing. `_get_property_list` / `_get` / `_set` is the supported way, and the properties are then real to every reflective caller, including `DotConfig`'s own `config_keys()`.

**Categories become `PROPERTY_USAGE_GROUP` entries, after the base class's own.** That constant is what `@export_group` compiles to and the only thing a reflective reader has to group by. `get_property_list()` includes `Resource`'s groups, and a reader tracks the most recent entry it has passed, so a group emitted before them would be overwritten by the class name again. The suite asserts the order rather than the absence, because the built-in one is legitimately there ([history](history.md#every-setting-under-one-heading-called-resource)).

## `from_config`, the path most existing code wants

Several projects already have a `DotConfig` full of player-facing settings, and dot-ui already generates a panel from one. Writing a schema beside such a config would be **two copies of one list**, this tree's most repeated bug.

`DotSettingsSchema.from_config(cfg, scopes)` reads it instead. Ranges come from `@export_range`, options from `@export_enum`, and anything in `sensitive_keys()` becomes `private`. What a config cannot say is the scope (which keys follow a person and which a server may clamp), so that arrives as a dictionary and nothing else is repeated.

`apply_to_config` is the way back, and both exist for one reason: **the config is what the game already reads.** A settings document that does not reach it is a document nothing consumes.

An `@export_enum` int is stored as the option **name**, not the index. An index means something different the day somebody inserts an option, and every saved document then quietly points at the wrong thing.

## The three scopes

`DEVICE` never synchronises: a synchronised resolution breaks itself every time a player switches machines. `ACCOUNT` lives under `shared_namespace`, as a **second document rather than a merged one**, so two games opting into one name share a sensitivity and a game that does not opt in is unaffected by either. `SERVER_CLAMPED` is the small set a server may cap.

The account half is read **after** the local half on load, so it wins for the keys it owns. Reading it first would let a stale local copy overwrite the shared one, which is the direction that loses the change a player just made on another machine.

## A server may clamp and may never read

There is no read direction in this addon. Capping field of view is a legitimate competitive rule; asking a client for its bindings, its audio device or its resolution is a fingerprint that survives a new account and every ban a moderator issues. `apply_server_clamps` returns which keys it accepted and sends nothing back.

**A clamp is a bound, not a value.** `get_value` is capped, `chosen_value` is the player's own, and `to_document` writes the choice. Every game that gets this wrong gets it wrong in the same direction, and the symptom is a setting that resets itself on every join.

`clamps_persist` defaults to false, and that is not a preference: a persisting clamp is a server permanently editing the settings of somebody who has left, with no way for them to tell which of their values came from a server they played on once.

## Unknown keys are kept

The downgrade path. A player who runs a newer build, changes a setting it added and goes back would otherwise lose it silently, and lose it again every time. They survive a `reset_all` too, because they belong to a build this one does not know about, and throwing them away is destroying somebody else's settings on their behalf.

## Coercion

- **Coercion corrects, and refuses only what is not the setting.** A settings file is edited by hand more often than any other file in a game. Refusing the whole document because one slider is out of range is a player who lost every other setting they had. The exception is an enum: an unknown option is refused outright, because silently substituting the default means a renamed option puts everybody back to "low" with nothing said.
- **`_clamp_number` returns a `Variant`.** Its two branches return different types, and declaring it `int` silently truncates every float setting in the schema: a volume slider that can only be 0 or 1, with every property about it reading correctly.
- **Compare across Variant types with `DotValue`.** `!=` between two mismatched Variant types is a runtime error in GDScript, not `true` ([history](history.md#a-comparison-that-aborted-a-green-suite)).
- **A value that changed only its Variant type is not a correction worth telling a player about.** `fov: 110 -> 110` is noise, and noise is what stops the real lines being read. The comparison is on what they print, which is exactly the question being asked.

## Storage

- **A missing document is a success.** "Nobody has ever saved settings here" is the first run of every installation. A store that reports it as an error makes every caller write the same special case, and that is the case somebody gets wrong; then a first run is a crash.
- **A corrupt file is renamed to `.broken`, not deleted.** The one thing worse than losing a settings file is losing it and being unable to show anybody what was in it.
- **`DotSettingsStoreFile` writes atomic JSON under `user://`, flushed for the web**; `DotSettingsStoreMemory` is a suite's store and the honest fallback for a refused storage quota.
- **`app_namespace`, not `namespace`.** `namespace` is a reserved word in GDScript, and the error it produces is *"Expected parameter name"*, which points at the punctuation rather than at the word.

## Bindings are opaque text

`DotSettingsDef.binding(key, default, category)` declares a key binding as a setting, bounded at 32 characters: long enough for `"Shift+Kp Subtract"` and nothing like long enough to be a payload. dot-menu's key table declares its rows this way.

**The value stays opaque here, and that is the seam.** dot-settings does not depend on dot-ui and has no opinion about what a key is called; dot-ui's `DotInputBinding` reads and writes the text. What this addon guarantees is what it guarantees for any string: the setting is declared, bounded, scoped and enumerable.

Text rather than a keycode because a settings document is written to disk, may be synchronised to an account, and is hand-edited. `"Y"` survives all three; `89` survives none of them, and is also a number that means a different key on a different layout.

## Deliberately not here

- **An account store.** It is an HTTP client against somebody's backbone, and whose backbone it is, is not this addon's decision. `remote_store` takes any subclass.
- **A settings screen.** dot-ui generates one from the `DotConfig`. Shipping a second would be two screens to keep in step.
- **Key binding storage beyond a string.** dot-ui has the rebinder and the conflict detection; this stores what it produces.
- **Cloud conflict resolution.** Two machines that both changed the same account setting while offline is a real problem and a bigger one than this; last-write-wins is what the shipped store does, and the addon says so rather than pretending.
