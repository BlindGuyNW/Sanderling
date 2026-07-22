module Frontend.View.Overview exposing (view)

{-| The overview: everything around the ship, and what can be done to it.

This is the one view that stays a table. Its columns are exactly what a player compares entries
by -- how far away a thing is, how fast it is going, whether it is a wreck or a frigate -- and a
table is the only shape that lets a screen reader move down one column and across to another.
Flattening each row into a sentence would read fluently and make it impossible to answer "what is
the nearest thing" without listening to every entry in full.

Being a table is not the same as being marked up as one. A `table` element carrying no `th`, no
`caption` and no `scope` is classified by the browser as a *layout* table and handed to the
screen reader as plain content: quick navigation by table skips past it, and cells are announced
with no idea which column they came from. That is what this view used to emit, and why the
overview read as a run of bare values. The header cells and caption below are not decoration --
they are what makes this reach the accessibility tree as a table at all.

-}

import Dict
import EveOnline.ParseUserInterface exposing (OverviewWindow, OverviewWindowEntry)
import Frontend.View.Common as Common exposing (Context)
import Html
import Html.Attributes as HA


view : Context event -> OverviewWindow -> Html.Html event
view context overviewWindow =
    Common.section context "Overview" (\_ -> [ tableHtml context overviewWindow ])


{-| The column names the client is showing, left to right.

These come from the header row the client draws, so they follow the player's own overview
settings and their language, and a column they have turned off never appears here.

-}
headersInOrder : OverviewWindow -> List String
headersInOrder overviewWindow =
    overviewWindow.entriesHeaders
        |> List.sortBy (Tuple.second >> .totalDisplayRegion >> .x)
        |> List.map Tuple.first


entriesInOrder : OverviewWindow -> List OverviewWindowEntry
entriesInOrder overviewWindow =
    overviewWindow.entries
        |> List.filter (.uiNode >> Common.isVisible)
        |> Common.inReadingOrder


tableHtml : Context event -> OverviewWindow -> Html.Html event
tableHtml context overviewWindow =
    let
        headers =
            headersInOrder overviewWindow

        entries =
            entriesInOrder overviewWindow

        {-
           The actions column exists only when input can actually be sent. Reading a saved
           memory reading has no route to a client, so adding the column then would put an
           empty cell on every row and, worse, leave the header row a cell wider than the
           body rows -- which is itself enough to confuse navigation by column.
        -}
        actionsHeader =
            if context.inputRoute == Nothing then
                []

            else
                [ Html.th [ HA.scope "col" ] [ Html.text "Actions" ] ]

        headerCells =
            (headers |> List.map (\header -> Html.th [ HA.scope "col" ] [ Html.text header ]))
                ++ actionsHeader
    in
    Html.table
        [ HA.style "border-collapse" "collapse" ]
        [ Html.caption [] [ Html.text (captionText entries) ]
        , Html.thead [] [ Html.tr [] headerCells ]
        , Html.tbody [] (entries |> List.map (rowHtml context headers))
        ]


captionText : List OverviewWindowEntry -> String
captionText entries =
    case List.length entries of
        0 ->
            "Overview, empty"

        1 ->
            "Overview, 1 object"

        count ->
            "Overview, " ++ String.fromInt count ++ " objects"


rowHtml : Context event -> List String -> OverviewWindowEntry -> Html.Html event
rowHtml context headers entry =
    let
        dataCells =
            headers |> List.map (cellHtml entry)

        actionCell =
            case Common.actionButtons context (subjectOfEntry entry) (actionsOnEntry entry) of
                [] ->
                    []

                buttons ->
                    [ Html.td [] buttons ]
    in
    Html.tr (backgroundAttributes entry) (dataCells ++ actionCell)


actionsOnEntry : OverviewWindowEntry -> List Common.Action
actionsOnEntry entry =
    [ Common.activate entry.uiNode, Common.menu entry.uiNode ]


{-| The cell for one column of one entry.

The name cell is the row's header, so that moving down another column -- the usual way to find
the nearest thing, or the fastest -- is announced against the object it belongs to instead of as
a bare number.

The `"Name"` key is the client's own English column name, and is the same key
`ParseUserInterface` reads `objectName` from. On a client running in another language the row
simply has no header cell, which costs the announcement of the name and nothing else. Treat this
as debt, in the sense of `CONVENTIONS.md` rule 4.

-}
cellHtml : OverviewWindowEntry -> String -> Html.Html event
cellHtml entry header =
    let
        content =
            [ entry.cellsTexts
                |> Dict.get header
                |> Maybe.withDefault ""
                |> Common.plainText
                |> Html.text
            ]
    in
    if header == "Name" then
        Html.th [ HA.scope "row" ] content

    else
        Html.td [] content


{-| What the buttons on this row say they act on.

The name alone is not always enough to tell two rows apart -- a belt of identical asteroids, or
several wrecks -- so the type and the distance come along when the client is showing them.

-}
subjectOfEntry : OverviewWindowEntry -> String
subjectOfEntry entry =
    let
        described =
            [ entry.objectName, entry.objectType, entry.objectDistance ]
                |> List.filterMap identity
                |> List.map Common.plainText
                |> List.filter (String.isEmpty >> not)
    in
    case described of
        [] ->
            {-
               A player whose overview shows none of the columns we know by name still gets
               buttons that name their row, using whatever text the client put in it.
            -}
            case entry.textsLeftToRight |> List.map Common.plainText |> List.filter (String.isEmpty >> not) of
                [] ->
                    "this object"

                texts ->
                    String.join ", " texts

        texts ->
            String.join ", " texts


{-| The client tints a row to mark it out -- a fleet member, something shooting at us.

Only the first fill is used. The colours are stacked in the client, but `background` given a list
of colours separated by spaces is not valid CSS and was being dropped by the browser anyway. None
of this reaches a screen reader; it is here for players who are reading the page as well as
hearing it.

-}
backgroundAttributes : OverviewWindowEntry -> List (Html.Attribute event)
backgroundAttributes entry =
    case entry.bgColorFillsPercent of
        [] ->
            []

        firstFill :: _ ->
            [ HA.style "background-color" (cssColorFromColorPercent firstFill) ]


cssColorFromColorPercent : EveOnline.ParseUserInterface.ColorComponents -> String
cssColorFromColorPercent colorPercent =
    let
        colorComponents =
            [ colorPercent.r, colorPercent.g, colorPercent.b ]
                |> List.map (\percent -> (percent * 255) // 100 |> String.fromInt)

        alpha =
            (colorPercent.a |> toFloat) / 100 |> String.fromFloat
    in
    "rgba(" ++ String.join "," (colorComponents ++ [ alpha ]) ++ ")"
