module Frontend.View.GenericWindow exposing (view)

{-| Presents a window of the game client without knowing what kind of window it is.

Every window the client builds carries a caption, header buttons the client labels with tooltips,
and content nodes that carry text. That is enough to read a window and click things in it, so a
window we have never written a specialized view for is still usable the day the client shows it,
rather than being invisible until someone adds a parse function for it.

-}

import EveOnline.ParseUserInterface exposing (GenericWindow, UITreeNodeWithDisplayRegion)
import Frontend.View.Common as Common exposing (Context)
import Html


{-| Windows such as the market can contain several hundred nodes carrying text. Presenting all of
them buries the window's own controls, so the list is cut off -- and says so, because a list that
silently stops reads as a list that ended.
-}
maximumNumberOfContentEntries : Int
maximumNumberOfContentEntries =
    100


view : Context event -> GenericWindow -> Html.Html event
view context window =
    Common.section context (titleForWindow window) (bodyHtml window)


titleForWindow : GenericWindow -> String
titleForWindow window =
    case window.caption of
        Just caption ->
            caption

        Nothing ->
            case window.name of
                Just name ->
                    name

                Nothing ->
                    window.typeName


bodyHtml : GenericWindow -> Context event -> List (Html.Html event)
bodyHtml window context =
    let
        headerButtonEntries =
            window.headerButtons
                |> List.filter (.uiNode >> Common.isVisible)
                |> Common.inReadingOrder
                |> List.map
                    (\button ->
                        { label = Common.labelForControl Common.noNameTable button.uiNode
                        , actions = [ Common.activate button.uiNode ]
                        }
                    )

        allContentEntries =
            contentEntries window

        shownContentEntries =
            allContentEntries |> List.take maximumNumberOfContentEntries

        numberNotShown =
            List.length allContentEntries - List.length shownContentEntries

        notShownHtml =
            if numberNotShown < 1 then
                []

            else
                [ Common.textLines
                    [ String.fromInt numberNotShown ++ " further entries in this window are not shown here." ]
                ]
    in
    (if headerButtonEntries == [] then
        []

     else
        [ Common.section context "Window controls" (\_ -> [ Common.actionList context headerButtonEntries ]) ]
    )
        ++ (if shownContentEntries == [] then
                [ Common.textLines [ "Nothing readable in this window." ] ]

            else
                Common.actionList context shownContentEntries :: notShownHtml
           )


contentEntries : GenericWindow -> List Common.Entry
contentEntries window =
    case window.contentNode of
        Nothing ->
            []

        Just contentNode ->
            contentNode
                |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                |> List.filter Common.isVisible
                |> Common.nodesInReadingOrder
                |> List.filterMap entryFromNode


{-| Only text the client is actually showing becomes an entry.

Tooltips are deliberately not used here. A tooltip describes a control the player is pointing at,
so listing it alongside the window's contents presents an explanation of a thing as if it were
the thing -- the wallet window would read as three paragraphs about what ISK and PLEX are, and
bury the balances. Tooltips label the header buttons, where they are the control's own name.

-}
entryFromNode : UITreeNodeWithDisplayRegion -> Maybe Common.Entry
entryFromNode node =
    case
        node.uiNode
            |> EveOnline.ParseUserInterface.getDisplayText
            |> Maybe.map Common.plainText
            |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
    of
        Nothing ->
            Nothing

        Just label ->
            Just
                { label = label
                , actions = [ Common.activate node, Common.menu node ]
                }
