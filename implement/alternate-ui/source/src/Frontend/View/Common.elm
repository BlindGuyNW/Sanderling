module Frontend.View.Common exposing
    ( Action
    , Context
    , Entry
    , actionList
    , activate
    , heading
    , inReadingOrder
    , isVisible
    , nodesInReadingOrder
    , labelForControl
    , menu
    , nested
    , noNameTable
    , plainText
    , section
    , textLines
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
import Html.Attributes.Aria
import Html.Events as HE
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


{-| Something the player can do to a node of the game client's user interface.
-}
type alias Action =
    { label : String
    , uiNode : UITreeNodeWithDisplayRegion
    , input : InputOnUINode
    }


activate : UITreeNodeWithDisplayRegion -> Action
activate uiNode =
    { label = "Activate", uiNode = uiNode, input = MouseClickLeft }


menu : UITreeNodeWithDisplayRegion -> Action
menu uiNode =
    { label = "Menu", uiNode = uiNode, input = MouseClickRight }


type alias Entry =
    { label : String
    , actions : List Action
    }


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
                case entry.actions |> List.head |> Maybe.map (.uiNode >> .totalDisplayRegion) of
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


entryHtml : Context event -> Entry -> Html.Html event
entryHtml context entry =
    let
        actionsHtml =
            case context.inputRoute of
                Nothing ->
                    []

                Just inputRoute ->
                    entry.actions
                        |> List.map
                            (\action ->
                                Html.button
                                    [ HE.onClick (inputRoute action.uiNode action.input)

                                    {-
                                       The button says only what it does, and names what it acts on
                                       to a screen reader separately. Putting the whole label in the
                                       button text reads the entry three times over, and some of
                                       these labels are a paragraph long.
                                    -}
                                    , Html.Attributes.Aria.ariaLabel (action.label ++ " " ++ shortened entry.label)
                                    ]
                                    [ Html.text action.label ]
                            )
    in
    Html.li
        [ HA.style "margin" "0.2em 0" ]
        (Html.text entry.label :: actionsHtml)


{-| Enough of a label to tell one entry from its neighbours, for places where repeating the whole
of it would drown out everything else.
-}
shortened : String -> String
shortened text =
    if String.length text <= 60 then
        text

    else
        (text |> String.left 60 |> String.trimRight) ++ "..."


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
