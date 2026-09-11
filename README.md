This is the **settings** asset for TMC's **Dot** collection. It adds game settings as a bounded, validated document: declared once, scoped to a device or an account or a server, stored through a pluggable store, and shareable between games on purpose.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## A setting is declared once, and the declaration is the interface

The alternative — a dictionary of whatever somebody happened to store — is what makes a settings system rot. Nobody can enumerate it, nothing can validate it, a typo'd key is indistinguishable from a setting nobody has chosen yet, and the screen that lists them carries a second copy of the list.

```gdscript
schema.add(DotSettingsDef.number(&"master_volume", 0.8, 0.0, 1.0, &"audio"))
schema.add(DotSettingsDef.integer(&"fov", 90, 70, 120, &"video")
    .with_scope(DotSettingsDef.Scope.SERVER_CLAMPED))
```

A screen enumerates the schema, a console completes against it, a store validates against it and a migration rewrites against it — so a new setting appears in all four without anybody editing four files.

**The settings screen is free.** `DotSettingsManager.to_config()` hands back a `DotConfig` whose properties *are* the schema's keys, built through `_get_property_list` / `_get` / `_set`, and dot-ui generates a panel from any `DotConfig`. Nothing in this asset names a `Control`.

## Three scopes, because a laptop and a desktop should disagree

| | |
| --- | --- |
| `DEVICE` | Resolution, audio device, thread count. **Never** synchronised: a synchronised resolution is a setting that breaks itself every time a player switches machines. |
| `ACCOUNT` | Sensitivity, crosshair, subtitles, language. Stored under `shared_namespace`, so two games that opt into the same name genuinely share one sensitivity — and a game that does not opt in is unaffected. |
| `SERVER_CLAMPED` | Field of view, view models, third person. A server may cap these. |

## A server may clamp, and may never read

That asymmetry is the whole of the server half. Capping field of view is a legitimate competitive rule; asking a client to report its key bindings, its audio device or its screen resolution is a **fingerprint** — a stable identifier assembled from settings, which survives a new account and every ban a moderator issues. So there is no read direction in this asset at all.

And a clamp is a **bound, not a value**:

```gdscript
settings.apply_server_clamps({"fov": 90})
settings.get_value(&"fov")      # 90 for a player who wanted 110
settings.chosen_value(&"fov")   # 110 — what the screen shows
```

Every game that gets this wrong gets it wrong in the same direction, and the symptom is a setting that appears to reset itself on every join. What is saved is the choice, never the cap.

## Written on change, not on quit

Debounced by a few hundred milliseconds so dragging a slider is one write, and written atomically through a temporary file and a rename. A game that saves settings on exit loses them whenever it crashes — and the moment a game is most likely to crash is while it is shutting down.

`user://` on the web is an IndexedDB mirror, so every write path flushes it; a removal is a write too.

## Unknown keys are kept

Not sloppiness — the downgrade path. A player who runs a newer build, changes a setting it added and goes back to an older one would otherwise lose it silently, and lose it again every single time. The unknown half is stored beside the known half and written back untouched.

A hand-edited file loses **one line**, not all of them: a value out of range is corrected, a value that cannot be read at all falls back to the default, and the two are reported in separate lists because they are different things to tell a player.

## Using it

```gdscript
var settings := DotSettingsManager.new()
settings.schema = my_schema
settings.local_store = DotSettingsStoreFile.new()
settings.app_namespace = &"my_game"
settings.shared_namespace = &"tmc_account"      # optional
add_child(settings)
settings.setup()

settings.get_float(&"master_volume")
settings.set_value(&"master_volume", 0.4)       # saved, debounced, atomically
```

`DotSettingsStore` is three methods. A file store and a memory store ship; an account store is an HTTP client against somebody's backbone, and whose backbone it is, is not this asset's decision.

## Installing

Copy `addons/dot_settings/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable dot-settings in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else.

## License

MIT.
