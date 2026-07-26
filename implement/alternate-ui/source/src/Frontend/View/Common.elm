module Frontend.View.Common exposing
    ( Context
    , Entry
    , actionList
    , control
    , controlActivateOnly
    , controlElement
    , controlIsSelected
    , decodeBoolOrInt
    , heading
    , inReadingOrder
    , isVisible
    , nodesInReadingOrder
    , labelForControl
    , nested
    , noNameTable
    , plainText
    , isScrollingContainer
    , pageControl
    , prose
    , section
    , sliderControl
    , textFieldControl
    , textLines
    , toggleControl
    , tooltipGestureAttribute
    )

{-| The building blocks every view of the game client is made of.

The point of putting these in one place is that the rules we want to hold for the whole page --
how headings nest, what order things are announced in, where a label comes from, and what happens
when we cannot send input -- are decided here once, instead of in each view separately. See
`implement/alternate-ui/CONVENTIONS.md`.

-}

import Dict
import EveOnline.ParseUserInterface exposing (UITreeNodeWithDisplayRegion)
import Frontend.InspectParsedUserInterface exposing (InputOnUINode(..), InputRoute)
import Html
import Html.Attributes as HA
import Html.Events as HE
import Json.Decode
import Regex


{-| What a view needs in order to render itself the same way as every other view: how to send
input to the game client, if we can at all, and how deeply nested in the page it sits.
-}
type alias Context event =
    { inputRoute : Maybe (InputRoute event)
    , headingLevel : Int
    }


{-| The context for the contents of a section, one heading level further in.
-}
nested : Context event -> Context event
nested context =
    { context | headingLevel = context.headingLevel + 1 }


heading : Context event -> String -> Html.Html event
heading context text =
    Html.node
        ("h" ++ String.fromInt (clamp 1 6 context.headingLevel))
        []
        [ Html.text text ]


{-| A titled part of the page. The body is built with a context one level deeper, so that the
heading levels a screen reader navigates by follow the nesting of the game client's own user
interface rather than the order in which we happened to write these views.
-}
section : Context event -> String -> (Context event -> List (Html.Html event)) -> Html.Html event
section context title body =
    Html.section [] (heading context title :: body (nested context))


{-| Text the player only reads, such as where they are or how full a container is.
-}
textLines : List String -> Html.Html event
textLines lines =
    lines
        |> List.map (\line -> Html.li [] [ Html.text line ])
        |> Html.ul []


{-| One thing in the game client, and what can be done to it.

`target` is the node the player acts on, or `Nothing` when the entry is only there to be read.
A single element carries both gestures the browser already gives every focusable thing -- a click
sends a left-click, and the context-menu gesture (the Applications key, or a right mouse click)
sends a right-click -- so there is one stop to land on, not a separate "Activate" and "Menu"
button. `canMenu` is whether the right-click is offered at all: a few controls, such as a window's
close button, have nothing behind a right-click.

`checkState` is the on/off state the client draws on a checkable control, carried the same way
the context-menu entries carry theirs: as `aria-pressed` on the button, so a screen reader
announces `toggle button, pressed` -- or, without an input route, as a word after the label.

`sliderPercent` makes the entry a slider: it renders as a `role="slider"` element the arrow keys
adjust, instead of a button.

`fieldText` makes the entry a text field: it renders as an edit box, and pressing Enter in it
sends what was typed into the corresponding field of the game client. The value carried is what
the game client's field holds right now, or `Nothing` when it is empty -- announced with the
label, since the edit box on the page starts empty rather than mirroring the client.

-}
type alias Entry =
    { label : String
    , target : Maybe ControlTarget
    , checkState : Maybe Bool
    , sliderPercent : Maybe Int
    , fieldText : Maybe (Maybe String)
    }


{-| `activate` is what pressing the entry sends -- a left-click for every ordinary control, or a
page scroll for the "Show more entries" controls a scrolling list grows.
-}
type alias ControlTarget =
    { node : UITreeNodeWithDisplayRegion
    , canMenu : Bool
    , activate : InputOnUINode
    }


{-| A control the player can activate and open a context menu on -- the common case.
-}
control : String -> UITreeNodeWithDisplayRegion -> Entry
control label node =
    { label = label, target = Just { node = node, canMenu = True, activate = MouseClickLeft }, checkState = Nothing, sliderPercent = Nothing, fieldText = Nothing }


{-| A control the player can only activate, with no context menu behind it.
-}
controlActivateOnly : String -> UITreeNodeWithDisplayRegion -> Entry
controlActivateOnly label node =
    { label = label, target = Just { node = node, canMenu = False, activate = MouseClickLeft }, checkState = Nothing, sliderPercent = Nothing, fieldText = Nothing }


{-| A control the client draws as checked or unchecked, such as a settings checkbox.
-}
toggleControl : String -> Bool -> UITreeNodeWithDisplayRegion -> Entry
toggleControl label checked node =
    { label = label, target = Just { node = node, canMenu = True, activate = MouseClickLeft }, checkState = Just checked, sliderPercent = Nothing, fieldText = Nothing }


{-| A slider, with its current value as a percentage and the track node clicks are aimed at.
-}
sliderControl : String -> Int -> UITreeNodeWithDisplayRegion -> Entry
sliderControl label percent trackNode =
    { label = label, target = Just { node = trackNode, canMenu = False, activate = MouseClickLeft }, checkState = Nothing, sliderPercent = Just percent, fieldText = Nothing }


{-| A text field of the game client, with what it currently holds, or `Nothing` when empty.
-}
textFieldControl : String -> Maybe String -> UITreeNodeWithDisplayRegion -> Entry
textFieldControl label currentText node =
    { label = label, target = Just { node = node, canMenu = False, activate = MouseClickLeft }, checkState = Nothing, sliderPercent = Nothing, fieldText = Just currentText }


{-| An entry that scrolls a list of the game client by the given number of pages, positive down.
Grown by the generic view on a scrolling list whose content continues beyond what the client has
built nodes for -- pressing it makes the client build the next rows, and the page picks them up
with its next reading.
-}
pageControl : String -> Int -> UITreeNodeWithDisplayRegion -> Entry
pageControl label pages scrollNode =
    { label = label
    , target = Just { node = scrollNode, canMenu = False, activate = VerticalScrollPage pages }
    , checkState = Nothing
    , sliderPercent = Nothing
    , fieldText = Nothing
    }


{-| Text that is only there to be read, with nothing to act on.
-}
prose : String -> Entry
prose label =
    { label = label, target = Nothing, checkState = Nothing, sliderPercent = Nothing, fieldText = Nothing }


{-| A list of things in the game client, each with the actions we can perform on it.

When there is no input route -- reading from a file rather than from a live client -- the labels
are still presented, only without buttons. Reading a saved reading stays useful.

-}
actionList : Context event -> List Entry -> Html.Html event
actionList context entries =
    entries
        |> collapseEntriesSharingRegion
        |> List.map (entryHtml context)
        |> Html.ul [ HA.style "list-style" "none", HA.style "padding-inline-start" "0" ]


{-| The client builds one control as a nest of nodes that all cover the same rectangle: a wrapper,
the control itself, and a background underlay. Anything that decides "is this a button" by the
type name matches all three, so a single OK button arrives here three times -- twice reading "OK",
once reading "underlay", because the underlay holds no text of its own and falls back to its
internal name.

They are the same pixels, so they are the same control. Only the first survives. Entries that
carry no action have no rectangle to compare and are always kept.

Collapsing here rather than in each parse function means every list gets it, which matters because
this nesting is how the client builds controls generally, not something peculiar to message boxes.

-}
collapseEntriesSharingRegion : List Entry -> List Entry
collapseEntriesSharingRegion entries =
    entries
        |> List.foldl
            (\entry ( kept, seenRegions ) ->
                case entry.target of
                    Nothing ->
                        ( entry :: kept, seenRegions )

                    Just target ->
                        --  Only click entries collapse: the nesting this collapse exists for is
                        --  how the client wraps one clickable control in several nodes. The two
                        --  "Show more entries" ends of one scrolling list share the scroll node's
                        --  rectangle without being the same control.
                        if target.activate /= MouseClickLeft then
                            ( entry :: kept, seenRegions )

                        else if List.member target.node.totalDisplayRegion seenRegions then
                            ( kept, seenRegions )

                        else
                            ( entry :: kept, target.node.totalDisplayRegion :: seenRegions )
            )
            ( [], [] )
        |> Tuple.first
        |> List.reverse


{-| One control, as a single focusable element whose accessible name is its own label.

A click sends a left-click to the node; the context-menu gesture -- the Applications key, or a
right mouse click -- sends a right-click when `canMenu`. This is the browser's own pairing of
Enter and Shift+F10 on any focusable element, so the whole control is one stop rather than a label
followed by separate "Activate" and "Menu" buttons. `preventDefaultOn` suppresses the browser's
own context menu so the game gets the right-click instead. Shift+F11 is the third per-element
gesture, `tooltipGestureAttribute`: hover the node so the client shows its tooltip, which the
page then announces.

Without an input route -- a reading loaded from a file -- it is the plain label, so a saved reading
still reads, only without anything to press.

This is shared so the overview table, which lays its controls out as cells rather than as a list,
labels and wires them exactly the way the list views do.

-}
controlElement : Maybe (InputRoute event) -> String -> UITreeNodeWithDisplayRegion -> Bool -> Html.Html event
controlElement maybeInputRoute label node canMenu =
    controlElementWithState maybeInputRoute label node canMenu Nothing


controlElementWithState : Maybe (InputRoute event) -> String -> UITreeNodeWithDisplayRegion -> Bool -> Maybe Bool -> Html.Html event
controlElementWithState maybeInputRoute label node canMenu checkState =
    controlElementForInput maybeInputRoute label node canMenu checkState MouseClickLeft


controlElementForInput : Maybe (InputRoute event) -> String -> UITreeNodeWithDisplayRegion -> Bool -> Maybe Bool -> InputOnUINode -> Html.Html event
controlElementForInput maybeInputRoute label node canMenu checkState activateInput =
    case maybeInputRoute of
        Nothing ->
            --  With no button to carry `aria-pressed`, the state becomes a word after the
            --  label, so a reading loaded from a file still tells which options were on.
            Html.text
                (case checkState of
                    Nothing ->
                        label

                    Just True ->
                        label ++ " (on)"

                    Just False ->
                        label ++ " (off)"
                )

        Just inputRoute ->
            let
                disabled =
                    controlIsDisabled node
            in
            Html.button
                (tooltipGestureAttribute inputRoute node
                    :: (if disabled then
                            --  `aria-disabled` rather than the `disabled` property: the property
                            --  takes the control out of the tab order, so a control the client
                            --  greys out would go missing from the page rather than announce
                            --  itself as unavailable, and there would be no way to find out it
                            --  exists. Nothing is wired to it, so pressing it sends nothing.
                            [ HA.attribute "aria-disabled" "true" ]

                        else
                            HE.onClick (inputRoute node activateInput)
                                :: (if canMenu then
                                        [ HE.preventDefaultOn "contextmenu"
                                            (Json.Decode.succeed ( inputRoute node MouseClickRight, True ))
                                        ]

                                    else
                                        []
                                   )
                       )
                    ++ (case checkState of
                            Nothing ->
                                []

                            Just checked ->
                                [ HA.attribute "aria-pressed"
                                    (if checked then
                                        "true"

                                     else
                                        "false"
                                    )
                                ]
                       )
                    --  `aria-current` rather than `aria-selected`: the latter is only honored on
                    --  role="tab"/option/row/gridcell/treeitem, and these are plain buttons in a
                    --  list. Giving them role="tab" would mean building a real tablist -- with the
                    --  arrow-key navigation and the aria-controls panel relationship a screen
                    --  reader then expects -- which the generic shell does not model. `aria-current`
                    --  needs no role and says the true thing: this is the current one of its set.
                    ++ (if controlIsSelected node then
                            [ HA.attribute "aria-current" "true" ]

                        else
                            []
                       )
                )
                [ Html.text label ]


{-| Whether the client holds a control to be disabled, and so inert to clicks.

The client states this outright, but names it differently in each widget family, so all four are
asked and any one of them answering is taken. All four measured on the
`Imicus (Frigate): Information` window, 2026-07-25:

  - `enabled` on the `ButtonIcon` family -- `0` on the window's `Previous` and `Next`, with no
    info history behind them yet, and `True` or `1` on every other icon button in the reading.
    Both spellings occur, hence `boolOrInt`.
  - `isDisabled` on `SkillPanelToggleButtonLarge`, the mastery level tabs. `False` on all six,
    including the levels not yet reached, which are dimmed but perfectly clickable.
  - `_enabled` on `Checkbox`. `True` on `Filter out acquired skills`.
  - `_interaction_state` on the newer `Button` family, which carries none of the first three.

`_interaction_state` is a Python *set* of state flags, read as a list of member names. The whole
enum is `selected | focused | disabled | pressed | hovered`, so four of its five members appear on
controls that are perfectly alive -- whether the set is empty says nothing, and only membership of
`disabled` does. `Apply Skill Points` holds it, dead because the character's unallocated skill
points fall short of the 17,300 the panel asks for; `Buy and train`, `Create Skill Plan` and
`Undock` hold empty sets.

A control carrying none of the four is reported enabled. That is the safe direction: announcing a
dead control as live costs a press that does nothing, which is what happened before any of this
existed, whereas announcing a live control as dead hides it.

An earlier version of this read the colours the client draws instead, because these keys were not
in `DictEntriesOfInterestKeys`. Do not go back to that. Dimming is drawn for at least three
unrelated reasons -- disabled, not-yet-reached, and plain decoration -- and no threshold separates
them; it marked the checkbox and the side navigation's ship header, both live.

-}
controlIsDisabled : UITreeNodeWithDisplayRegion -> Bool
controlIsDisabled node =
    let
        dictEntry key decoder =
            node.uiNode.dictEntriesOfInterest
                |> Dict.get key
                |> Maybe.andThen (Json.Decode.decodeValue decoder >> Result.toMaybe)

        --  An element with no reader of its own stays an object; it is not `disabled`, and
        --  decoding the list must not fail because of it.
        interactionStateNames =
            Json.Decode.list
                (Json.Decode.oneOf [ Json.Decode.string, Json.Decode.succeed "" ])
    in
    [ dictEntry "enabled" decodeBoolOrInt |> Maybe.map not
    , dictEntry "isDisabled" decodeBoolOrInt
    , dictEntry "_enabled" decodeBoolOrInt |> Maybe.map not
    , dictEntry "_interaction_state" interactionStateNames
        |> Maybe.map (List.member "disabled")
    ]
        |> List.filterMap identity
        |> List.any identity


{-| Whether the client holds this control to be the current one of its set.

Two names, by family, both measured 2026-07-25 on the `Imicus (Frigate): Information` window and
the station lobby beside it:

  - `_selected` on `Tab`, `InventoryTab` and `SideNavigationEntry`, and on `ColumnHeader`, where it
    marks the sorted column. `True` on exactly one member of each strip.
  - `isSelected` on `SkillPanelToggleButtonLarge` and the `ButtonIcon` family.

Where neither is present the drawing still decides, which keeps the inventory container tree
reading as it did: the client marks a selected list entry with a `SelectionIndicatorLine` inside
the entry's own subtree. That test cannot reach a tab strip, which draws its one line beside the
tabs rather than inside the selected one, and the keys above are what close that gap.

-}
controlIsSelected : UITreeNodeWithDisplayRegion -> Bool
controlIsSelected node =
    let
        selectedFlag key =
            node.uiNode.dictEntriesOfInterest
                |> Dict.get key
                |> Maybe.andThen (Json.Decode.decodeValue decodeBoolOrInt >> Result.toMaybe)
    in
    case ( selectedFlag "_selected", selectedFlag "isSelected" ) of
        ( Just selected, _ ) ->
            selected

        ( Nothing, Just selected ) ->
            selected

        ( Nothing, Nothing ) ->
            EveOnline.ParseUserInterface.subtreeShowsSelectionIndicator node


{-| The client writes a flag either as a python bool or as 0/1, depending on the widget.
-}
decodeBoolOrInt : Json.Decode.Decoder Bool
decodeBoolOrInt =
    Json.Decode.oneOf
        [ Json.Decode.bool
        , Json.Decode.int |> Json.Decode.map (\asInt -> asInt /= 0)
        ]


entryHtml : Context event -> Entry -> Html.Html event
entryHtml context entry =
    Html.li
        [ HA.style "margin" "0.2em 0" ]
        [ case entry.target of
            Nothing ->
                Html.text entry.label

            Just target ->
                case ( entry.sliderPercent, entry.fieldText ) of
                    ( Just percent, _ ) ->
                        sliderElement context.inputRoute entry.label percent target.node

                    ( Nothing, Just currentText ) ->
                        textFieldElement context.inputRoute entry.label currentText target.node

                    ( Nothing, Nothing ) ->
                        controlElementForInput context.inputRoute entry.label target.node target.canMenu entry.checkState target.activate
        ]


{-| Shift+F11 on a focused control hovers its node in the game client, which makes the client
show the node's tooltip for the page to announce. The keys with a per-element meaning in a screen
reader's browse mode are only the ones the browser itself routes to the focused element -- Enter,
and Shift+F10 for the context menu -- so a third verb has to ride on a key combination that
neither the screen reader nor the browser has a binding for. Shift+F11 is such a key: F11 alone
is the browser's fullscreen toggle, shifted it is free, and NVDA's browse mode has no gesture on
it. A decoder that fails on every other key leaves those keys to their usual meaning.
-}
tooltipGestureDecoder : InputRoute event -> UITreeNodeWithDisplayRegion -> Json.Decode.Decoder ( event, Bool )
tooltipGestureDecoder inputRoute node =
    Json.Decode.map2 Tuple.pair
        (Json.Decode.field "key" Json.Decode.string)
        (Json.Decode.field "shiftKey" Json.Decode.bool)
        |> Json.Decode.andThen
            (\( key, shiftKey ) ->
                if key == "F11" && shiftKey then
                    Json.Decode.succeed ( inputRoute node MouseHover, True )

                else
                    Json.Decode.fail "not the tooltip gesture"
            )


tooltipGestureAttribute : InputRoute event -> UITreeNodeWithDisplayRegion -> Html.Attribute event
tooltipGestureAttribute inputRoute node =
    HE.preventDefaultOn "keydown" (tooltipGestureDecoder inputRoute node)


{-| A slider of the game client, as the `role="slider"` element a screen reader expects: it
announces its value, and the arrow keys adjust it -- Home and End jump to the ends. Each key
sends a click at the corresponding position on the track, because that is how the client's own
sliders are set: the handle jumps to where the track is clicked.

Without an input route it is the label and value as plain text, so a saved reading still tells
where every slider stood.

-}
sliderElement : Maybe (InputRoute event) -> String -> Int -> UITreeNodeWithDisplayRegion -> Html.Html event
sliderElement maybeInputRoute label percent node =
    let
        labelWithValue =
            label ++ ": " ++ String.fromInt percent ++ " %"
    in
    case maybeInputRoute of
        Nothing ->
            Html.text labelWithValue

        Just inputRoute ->
            let
                eventForPercent targetPercent =
                    inputRoute node
                        (Frontend.InspectParsedUserInterface.MouseClickAtHorizontalFraction
                            (toFloat (clamp 0 100 targetPercent) / 100)
                        )

                keyDecoder =
                    Json.Decode.field "key" Json.Decode.string
                        |> Json.Decode.andThen
                            (\key ->
                                case key of
                                    "ArrowUp" ->
                                        Json.Decode.succeed (percent + 5)

                                    "ArrowRight" ->
                                        Json.Decode.succeed (percent + 5)

                                    "ArrowDown" ->
                                        Json.Decode.succeed (percent - 5)

                                    "ArrowLeft" ->
                                        Json.Decode.succeed (percent - 5)

                                    "Home" ->
                                        Json.Decode.succeed 0

                                    "End" ->
                                        Json.Decode.succeed 100

                                    _ ->
                                        Json.Decode.fail "not a slider key"
                            )
                        |> Json.Decode.map (\targetPercent -> ( eventForPercent targetPercent, True ))
            in
            Html.div
                [ HA.attribute "role" "slider"
                , HA.tabindex 0
                , HA.attribute "aria-label" label
                , HA.attribute "aria-valuemin" "0"
                , HA.attribute "aria-valuemax" "100"
                , HA.attribute "aria-valuenow" (String.fromInt percent)
                , HA.attribute "aria-valuetext" (String.fromInt percent ++ " %")
                , HE.preventDefaultOn "keydown"
                    (Json.Decode.oneOf [ tooltipGestureDecoder inputRoute node, keyDecoder ])
                ]
                [ Html.text labelWithValue ]


{-| A text field of the game client, as the edit box a screen reader expects: what the game's
field holds is in the box, readable with the arrow keys like any edit content, and typing a new
text and pressing Enter sends it to replace the field's content in the game client.

The content rides in as the `value` *attribute*, deliberately not the property: the attribute is
only the box's default, so it fills the box on first render and follows later readings -- until
the player types, which marks the box dirty and ends the attribute's influence. That is exactly
the handover wanted here. Mirroring through the value property instead would re-set the box on
every reading, wiping whatever the player is in the middle of typing.

Without an input route it is the label and content as plain text, so a saved reading still tells
what every field held.

-}
textFieldElement : Maybe (InputRoute event) -> String -> Maybe String -> UITreeNodeWithDisplayRegion -> Html.Html event
textFieldElement maybeInputRoute label currentText node =
    case maybeInputRoute of
        Nothing ->
            Html.text
                (label
                    ++ (case currentText of
                            Nothing ->
                                ""

                            Just content ->
                                ", currently: " ++ content
                       )
                    ++ " (text field)"
                )

        Just inputRoute ->
            let
                enterKeyDecoder =
                    Json.Decode.field "key" Json.Decode.string
                        |> Json.Decode.andThen
                            (\key ->
                                if key == "Enter" then
                                    Json.Decode.at [ "target", "value" ] Json.Decode.string

                                else
                                    Json.Decode.fail "not the Enter key"
                            )
                        |> Json.Decode.map
                            (\typedText ->
                                ( inputRoute node (TypeTextIntoField typedText), True )
                            )
            in
            Html.input
                [ HA.type_ "text"
                , HA.attribute "aria-label" label
                , HA.attribute "value" (currentText |> Maybe.withDefault "")
                , HE.preventDefaultOn "keydown"
                    (Json.Decode.oneOf [ tooltipGestureDecoder inputRoute node, enterKeyDecoder ])
                ]
                []


{-| The label to present for a control, preferring what the game client itself says over anything
we maintain by hand: the client's own tooltip, then the text the control contains, then a name we
translate ourselves, and only then the client's internal name.

Pass `noNameTable` where we have no hand-written translations for this kind of control.

-}
labelForControl : (String -> Maybe String) -> UITreeNodeWithDisplayRegion -> String
labelForControl translateName node =
    let
        containedText =
            node
                |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
                |> List.map Tuple.first
                |> List.filterMap EveOnline.ParseUserInterface.discardUnreadableText
                |> List.head

        internalName =
            node.uiNode |> EveOnline.ParseUserInterface.getNameFromDictEntries
    in
    [ node.uiNode
        |> EveOnline.ParseUserInterface.getHintTextFromDictEntries
        |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
        |> Maybe.map plainText
    , containedText |> Maybe.map plainText
    , internalName |> Maybe.andThen translateName
    , internalName
    ]
        |> List.filterMap identity
        |> List.filterMap EveOnline.ParseUserInterface.discardUnreadableText
        |> List.head
        |> Maybe.withDefault "(unlabeled)"


noNameTable : String -> Maybe String
noNameTable _ =
    Nothing


{-| The client's markup turned into the text a player would see.

`removeMarkupTags` drops whole tags, which is what the parse functions need. What reaches a
screen reader has to go further: the client also emits tags cut off at the end of a truncated
string, and HTML entities that would otherwise be read out as "ampersand n b s p".

`<t>` is not decoration but the client's tab: it is what separates the cells of a row packed
into one string, so it becomes a separator instead of vanishing -- dropped with the other tags,
`8`, `5,838` and `3.00 ISK` read as one number. Observed 2026-07-23 in the regional market's
order rows.

-}
plainText : String -> String
plainText text =
    text
        |> replaceWithRegex "<t>" ", "
        |> EveOnline.ParseUserInterface.removeMarkupTags
        |> replaceWithRegex "<[^>]*$" ""
        |> replaceWithRegex "&nbsp;" " "
        |> replaceWithRegex "&lt;" "<"
        |> replaceWithRegex "&gt;" ">"
        |> replaceWithRegex "&quot;" "\""
        |> replaceWithRegex "&#39;" "'"
        |> replaceWithRegex "&amp;" "&"
        |> String.trim


replaceWithRegex : String -> String -> String -> String
replaceWithRegex pattern replacement text =
    case Regex.fromString pattern of
        Nothing ->
            text

        Just regex ->
            Regex.replace regex (always replacement) text


{-| Whether the game client is actually showing this node. Announcing something the player cannot
see would be misleading, and offering a click on it would send input that lands somewhere else.

Hidden means alpha, not absence: the client leaves nodes in the tree and makes them transparent.
A region-only check read the skill queue's timeline tick labels -- `6h, 12h, 18h, 24h` in a
container at `_opacity` 0 -- into an empty queue. Observed 2026-07-23. Only the node's own
opacity needs checking here, because the walk that consults this descends the tree and stops at
the transparent container before ever reaching its children.

-}
isVisible : UITreeNodeWithDisplayRegion -> Bool
isVisible node =
    (0 < node.totalDisplayRegionVisible.width)
        && (0 < node.totalDisplayRegionVisible.height)
        && (node.uiNode
                |> EveOnline.ParseUserInterface.getOpacityFloatFromDictEntries
                |> Maybe.map (\opacity -> 0.05 < opacity)
                |> Maybe.withDefault True
           )


{-| A node that clips and scrolls its content, told by the client classes in its inheritance
chain. The debt `CONVENTIONS.md` rule 4 describes: `ScrollContainer` was observed in the settings
window and `Scroll` in the overview settings window, both 2026-07-23; `BasicDynamicScroll` is the
base the ordinary list windows build from.
-}
isScrollingContainer : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> Bool
isScrollingContainer typeHierarchy node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName

        inheritanceChain =
            Dict.get typeName typeHierarchy |> Maybe.withDefault [ typeName ]
    in
    [ "ScrollContainer", "Scroll", "BasicDynamicScroll" ]
        |> List.any (\className -> List.member className inheritanceChain)


{-| The order the player would read these in on screen: down the window first, then across.
The order the parse functions happen to produce is not meaningful, so every list of entries is
sorted here before it is presented.
-}
inReadingOrder : List { a | uiNode : UITreeNodeWithDisplayRegion } -> List { a | uiNode : UITreeNodeWithDisplayRegion }
inReadingOrder =
    List.sortBy
        (\item ->
            ( item.uiNode.totalDisplayRegion.y, item.uiNode.totalDisplayRegion.x )
        )


nodesInReadingOrder : List UITreeNodeWithDisplayRegion -> List UITreeNodeWithDisplayRegion
nodesInReadingOrder =
    List.sortBy
        (\node ->
            ( node.totalDisplayRegion.y, node.totalDisplayRegion.x )
        )
