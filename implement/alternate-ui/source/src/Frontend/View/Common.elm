module Frontend.View.Common exposing
    ( Context
    , Entry
    , actionList
    , control
    , controlActivateOnly
    , controlElement
    , heading
    , inReadingOrder
    , isVisible
    , nodesInReadingOrder
    , labelForControl
    , nested
    , noNameTable
    , plainText
    , prose
    , section
    , sliderControl
    , textLines
    , toggleControl
    )

{-| The building blocks every view of the game client is made of.

The point of putting these in one place is that the rules we want to hold for the whole page --
how headings nest, what order things are announced in, where a label comes from, and what happens
when we cannot send input -- are decided here once, instead of in each view separately. See
`implement/alternate-ui/CONVENTIONS.md`.

-}

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

-}
type alias Entry =
    { label : String
    , target : Maybe ControlTarget
    , checkState : Maybe Bool
    , sliderPercent : Maybe Int
    }


type alias ControlTarget =
    { node : UITreeNodeWithDisplayRegion
    , canMenu : Bool
    }


{-| A control the player can activate and open a context menu on -- the common case.
-}
control : String -> UITreeNodeWithDisplayRegion -> Entry
control label node =
    { label = label, target = Just { node = node, canMenu = True }, checkState = Nothing, sliderPercent = Nothing }


{-| A control the player can only activate, with no context menu behind it.
-}
controlActivateOnly : String -> UITreeNodeWithDisplayRegion -> Entry
controlActivateOnly label node =
    { label = label, target = Just { node = node, canMenu = False }, checkState = Nothing, sliderPercent = Nothing }


{-| A control the client draws as checked or unchecked, such as a settings checkbox.
-}
toggleControl : String -> Bool -> UITreeNodeWithDisplayRegion -> Entry
toggleControl label checked node =
    { label = label, target = Just { node = node, canMenu = True }, checkState = Just checked, sliderPercent = Nothing }


{-| A slider, with its current value as a percentage and the track node clicks are aimed at.
-}
sliderControl : String -> Int -> UITreeNodeWithDisplayRegion -> Entry
sliderControl label percent trackNode =
    { label = label, target = Just { node = trackNode, canMenu = False }, checkState = Nothing, sliderPercent = Just percent }


{-| Text that is only there to be read, with nothing to act on.
-}
prose : String -> Entry
prose label =
    { label = label, target = Nothing, checkState = Nothing, sliderPercent = Nothing }


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
                case entry.target |> Maybe.map (.node >> .totalDisplayRegion) of
                    Nothing ->
                        ( entry :: kept, seenRegions )

                    Just region ->
                        if List.member region seenRegions then
                            ( kept, seenRegions )

                        else
                            ( entry :: kept, region :: seenRegions )
            )
            ( [], [] )
        |> Tuple.first
        |> List.reverse


{-| One control, as a single focusable element whose accessible name is its own label.

A click sends a left-click to the node; the context-menu gesture -- the Applications key, or a
right mouse click -- sends a right-click when `canMenu`. This is the browser's own pairing of
Enter and Shift+F10 on any focusable element, so the whole control is one stop rather than a label
followed by separate "Activate" and "Menu" buttons. `preventDefaultOn` suppresses the browser's
own context menu so the game gets the right-click instead.

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
            Html.button
                (HE.onClick (inputRoute node MouseClickLeft)
                    :: (if canMenu then
                            [ HE.preventDefaultOn "contextmenu"
                                (Json.Decode.succeed ( inputRoute node MouseClickRight, True ))
                            ]

                        else
                            []
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
                )
                [ Html.text label ]


entryHtml : Context event -> Entry -> Html.Html event
entryHtml context entry =
    Html.li
        [ HA.style "margin" "0.2em 0" ]
        [ case entry.target of
            Nothing ->
                Html.text entry.label

            Just target ->
                case entry.sliderPercent of
                    Just percent ->
                        sliderElement context.inputRoute entry.label percent target.node

                    Nothing ->
                        controlElementWithState context.inputRoute entry.label target.node target.canMenu entry.checkState
        ]


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
                , HE.preventDefaultOn "keydown" keyDecoder
                ]
                [ Html.text labelWithValue ]


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

-}
plainText : String -> String
plainText text =
    text
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
-}
isVisible : UITreeNodeWithDisplayRegion -> Bool
isVisible node =
    0 < node.totalDisplayRegionVisible.width && 0 < node.totalDisplayRegionVisible.height


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
