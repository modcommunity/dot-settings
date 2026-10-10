# dot-settings

A player's settings as a bounded document, with three scopes (device, account, server-clamped) and a server that may clamp but never read. `DotSettingsConfig` turns a schema into a `DotConfig`, so dot-ui draws the screen.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to settings.

**The distributable is `addons/dot_settings/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). It names nothing from dot-ui; dot-menu builds on it.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the config bridge, `from_config`, scopes, clamps, unknown keys, coercion, storage, bindings, what is not here |
| [docs/history.md](docs/history.md) | the comparison that aborted a green suite, and the "Resource" heading |

## Layout

| Path | What |
| --- | --- |
| `core/dot_settings_def.gd` | `DotSettingsDef`: one setting; kind, scope, bounds, coercion; `binding()` |
| `core/dot_settings_schema.gd` | `DotSettingsSchema`: all of them, a version, the migrations. The only list. `from_config`, `apply_to_config` |
| `core/dot_settings_config.gd` | `DotSettingsConfig`: a `DotConfig` built from a schema at runtime; the dot-ui bridge |
| `core/dot_settings_policy.gd` | `DotSettingsPolicy`: what a server may touch; a `DotConfig` |
| `store/dot_settings_store.gd` | `DotSettingsStore`: three methods; a missing document is a success |
| `store/dot_settings_store_file.gd` | `DotSettingsStoreFile`: atomic JSON under `user://`, flushed for the web |
| `store/dot_settings_store_memory.gd` | `DotSettingsStoreMemory`: a suite's, and the fallback for a refused quota |
| `runtime/dot_settings_manager.gd` | `DotSettingsManager`: the node a game holds |
| `examples/settings_selftest.tscn` | the suite |

Paths except `examples/` are in `addons/dot_settings/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/settings_selftest.tscn`. **Read the stderr even when it exits 0**: this is the addon that proved why ([history](docs/history.md#a-comparison-that-aborted-a-green-suite)).

## Rules that bite

- Runtime properties go through `_get_property_list` / `_get` / `_set`; a dynamic assignment on an `Object` sets nothing. [design](docs/design.md#dotsettingsconfig-a-dotconfig-built-from-a-schema)
- Category groups are emitted after the base class's own groups. [design](docs/design.md#dotsettingsconfig-a-dotconfig-built-from-a-schema)
- A game with a `DotConfig` of player settings uses `from_config` / `apply_to_config`, never a second list. [design](docs/design.md#from_config-the-path-most-existing-code-wants)
- Enums are stored by option name, never index. [design](docs/design.md#from_config-the-path-most-existing-code-wants)
- `DEVICE` never syncs; `ACCOUNT` is a second document under `shared_namespace`, read after the local one. [design](docs/design.md#the-three-scopes)
- A server clamps and never reads; a clamp bounds `get_value` and never touches `chosen_value` or the saved document; `clamps_persist` stays false by default. [design](docs/design.md#a-server-may-clamp-and-may-never-read)
- Unknown keys are kept, through `reset_all` too. [design](docs/design.md#unknown-keys-are-kept)
- Coercion corrects; only an unknown enum option is refused. `_clamp_number` returns `Variant`. [design](docs/design.md#coercion)
- Compare Variants whose types you do not control with dot-core's `DotValue`, never `!=`. [design](docs/design.md#coercion)
- A missing document is a success; a corrupt one is renamed `.broken`. Use `app_namespace`, never `namespace`. [design](docs/design.md#storage)
- A binding is opaque text, at most 32 characters, declared with `DotSettingsDef.binding()`. [design](docs/design.md#bindings-are-opaque-text)

Deliberately not here: an account store, a settings screen, binding logic, cloud conflict resolution. [design](docs/design.md#deliberately-not-here)
