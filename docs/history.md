# History

Bugs worth recognising if they come back. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## A comparison that aborted a green suite

**`!=` between two mismatched Variant types is a runtime ERROR in GDScript, not `true`.** `coerce_document` compared a coerced int with the String it came from, the expression was abandoned, and the section aborted, while the suite reported "0 failed" and exited 0.

Two things came out of it, both family-wide now:

1. **`DotValue` is in dot-core**, with a self-test. dot-npc-ai's blackboard had this exact bug (`get_value(...) != MISSING` answered false for every value that was not a `StringName`), so it was the second time, and the class is the family's answer. Use it anywhere either side is a `Variant` whose type you do not control.
2. **Every suite asserts a total number of checks, not just a section count.** The section counter cannot catch this: the section had already announced itself before it aborted. See [game-dev/docs/testing.md](../../../docs/testing.md).

## A dynamic property that set nothing

Godot refuses a dynamic property on an `Object`: `cfg.some_new_key = 1` pushes an error and sets nothing. This family shipped that once: a game descriptor whose `module` was assigned that way named no module at all, and the failure was a scene with nothing behind it. That is why `DotSettingsConfig` goes through `_get_property_list` / `_get` / `_set`.

## A binding kind with no way to declare one

`DotSettingsDef.Kind.BINDING` existed from the start with no constructor, so nothing in the family ever declared a binding as a setting: every game's keys lived in the bindings panel's own file. `DotSettingsDef.binding()` was added.

## Every setting under one heading called "Resource"

`DotSettingsDef.category` carried "Video", "Audio", "Gameplay" from the start, every schema set it, and `DotSettingsConfig._get_property_list` emitted no `PROPERTY_USAGE_GROUP` entry at all. A generated settings screen came out with a single heading called **"Resource"** (the base class name) over everything. It survived because everything about it looked right: the panel drew, every row was correct, and the heading was a plausible word. A screenshot of the menus is what showed it.

## The account document that never won

The design said the account half is read after the game's own so it wins, and the code did read it second, into the top level of the raw document. The migration step then built the values from `values` and copied a top-level key only when `values` did not already hold it, and `to_document` wrote every value, account keys included, into the game's own document. So once a game had saved once, its own copy of the sensitivity beat the account's on every load, and a change made in another game never arrived. The suite missed it because its second game had an empty document of its own, which cannot tell "the account wins" from "the only copy wins". The fix stamps each account value with when it was chosen and merges per key on load and before every save; the suite's precedence section has both games save before either reads the other's change.
