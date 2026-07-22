# Conventions for the alternate UI

This UI exists so the game client can be played through a screen reader. That single purpose
decides most of what follows: the page is not a rendering of the client, it is a *reading* of it,
and the thing being optimized is what a person hears, in what order, and how much of it they have
to sit through to find what they wanted.

These rules exist because the views were drifting apart by copy-paste. Each one had picked its own
heading level, its own list markup, its own way of deciding whether a label becomes a button, and
its own English name tables. None of that is a per-view decision.

## 1. The client's own layer stack decides order and precedence

The game client stacks its interface in layers, named on the `LayerCore` nodes directly below the
UI root: `l_modal`, `l_menu`, `l_utilmenu`, `l_main`, `l_abovemain`, `l_alwaysvisible`,
`l_viewstate`, plus a few that only carry tooltips and transitions. The client uses that stack to
decide what is drawn over what, which makes it the client's own answer to "what has the player's
attention right now".

Use it. `ParseUserInterface.layerNamesInPresentationOrder` is that stack in the order things
should be presented, most demanding first. A modal dialog is announced before anything else,
because until it is answered the client will ignore everything the player does.

Do not hand-order sections in the view. A window that appears in a new place on screen should turn
up in the right place on the page without anyone editing a list.

## 1a. The thing to design against is a client update

`ParseUserInterface.elm` is ours to reshape. There are no external consumers to keep happy -- this
repo exists to serve the alternate UI, and nothing here needs to stay stable for anyone else.

The pressure that does matter is CCP changing the client. Every parse function keyed to an exact
`pythonObjectTypeName`, and every hand-written name table, is a thing that breaks on patch day and
takes a window with it.

So prefer what the client tells us over what we assert about it, in this order:

- Structure the client maintains for its own sake -- the layer stack, the `content` /
  `headerParent` / `main` window shape -- over a list of type names we wrote down.
- `_hint` and displayed text over a name table.
- Degrading over disappearing. This is what rule 2 buys: when a specialized parse function stops
  matching, the window still renders through the generic shell instead of silently vanishing.
  A page that gets rougher after a patch is recoverable; a page that goes blank is not.

When a specialized view and the generic shell disagree, the generic shell is the safety net. Do
not remove a window from the generic path except by adding it to the exclusion in
`displayOtherWindows`, so that losing the specialized view brings the generic one back.

## 2. Every window renders, whether or not we have a view for it

Windows in `l_main` are uniform: a `content` child holding `headerParent` and `main`, a
`window_controls_cont`, and a `Resizer`. `ParseUserInterface.parseGenericWindow` reads that shape,
and `Frontend.View.GenericWindow` presents it -- caption as the heading, header buttons with their
tooltips as labels, and the text the window contains as entries that can be clicked.

So a window we have never written a specialized view for is still readable and clickable the day
the client shows it. Writing a specialized view is an improvement on a working page, not the price
of a window existing at all.

When adding a specialized view, add the window's node address to the exclusion in
`displayOtherWindows` so it is not presented twice.

## 3. Labels come from the client

`Frontend.View.Common.labelForControl` applies one order of preference:

1. `_hint` -- the client's own tooltip. Localized, correct, and free.
2. The text the node contains.
3. A name we translate by hand.
4. The client's internal `_name`, as a last resort.

Never write step 3 without checking that steps 1 and 2 are really empty. Most controls carry a
usable `_hint`: `Close`, `Minimize`, `Stack All`, `Sort By`, `Open Wallet` all come straight from
the client.

Text that reaches a person goes through `Common.plainText`, which strips the client's markup,
including tags cut off at the end of a truncated string, and decodes HTML entities. `&nbsp;` read
aloud is not a space.

## 4. Hand-written name tables are a liability, and are documented as one

Some controls -- the Neocom buttons, the station service buttons -- have no `_hint` until the
player points at them, so a table is the only option. Each such table carries a comment saying
when and where the names were observed, in the same style as the cases in
`tests/ParseMemoryReadingTest.elm`. Entries come out as soon as the client is seen to supply the
name itself. These tables are English-only and go stale; treat every entry as debt.

## 5. Heading levels express nesting, not visual weight

h1 for the page, h2 for a region, h3 for a window, h4 for a section within a window. Headings are
how a screen reader user navigates; a page of flat `h3`s is a page with no structure.

Views never emit a heading tag directly. `Common.section` takes the heading level from the
`Context` and hands the body a context one level deeper, so nesting follows the client's structure
rather than the order the views were written in.

## 6. Do not announce what is not there, and do not offer input that cannot land

`Common.isVisible` gates both. A node with an empty visible region is not shown by the client, so
announcing it misleads, and clicking it sends input somewhere else.

Two related honesty rules:

- Text the memory reading could not recover arrives as the literal string
  `Failed to read string bytes.`. `ParseUserInterface.discardUnreadableText` drops it. Never
  present it as something the game said.
- A tooltip is not content. It describes a control the player is pointing at. Listing tooltips
  among a window's contents turns the wallet into three paragraphs about what ISK is, with the
  balance buried underneath. Tooltips label controls; they are not entries.

## 7. Ordering is explicit, and taken from the client's geometry

`Common.inReadingOrder` and `Common.nodesInReadingOrder` sort by `(y, x)` -- down the window, then
across. The order a parse function happens to produce is an accident of how it walks the tree, and
is not the order anything appears on screen. Sort at the point of display.

## 8. Say when a list is cut off

`GenericWindow` caps how many entries it presents, because the market window would otherwise bury
its own controls under several hundred lines. When it cuts, it says how many it left out. A list
that silently stops reads as a list that ended.

## 9. Buttons say what they do; the entry says what it is

An action button's visible text is the verb alone -- `Activate`, `Menu` -- with an `aria-label`
naming what it acts on. Putting the full label in the button text reads every entry three times
over, and some of these labels are a paragraph long.

## Shape of the code

- `Frontend/View/Common.elm` -- `Context`, `section`, `actionList`, `labelForControl`,
  `plainText`, the visibility gate, the ordering helpers. Everything above is enforced here so it
  does not have to be remembered in each view.
- `Frontend/View/GenericWindow.elm` -- the fallback renderer for any window.
- `Frontend/Main.elm` -- composition, and the specialized views not yet moved out.

Views return `Html.Html event` and take a `Context`. They are expected to build through the
helpers in `Common` rather than reaching for `Html.h3`, `Html.ul`, or `HE.onClick` directly.

## Testing

Parsing is tested offline: a client string that the parser gets wrong becomes a case in
`tests/ParseMemoryReadingTest.elm`, with a comment giving the date and where it was observed.

Views are verified against a running client, because what matters about them -- what is announced,
in what order -- is not visible in the Elm types. `tools/AlternateUiApi.ps1` reads the live tree
and sends input; `./start-alternate-ui.ps1 -Port 8080` runs a second instance so a change can be
tried without disturbing a working one.
