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

        headerCells =
            headers |> List.map (\header -> Html.th [ HA.scope "col" ] [ Html.text header ])
    in
    Html.table
        [ HA.style "border-collapse" "collapse" ]
        [ Html.caption [] [ Html.text (captionText entries) ]
        , Html.thead [] [ Html.tr [] headerCells ]
        , Html.tbody [] (entries |> List.map (rowHtml context (handleColumn headers) headers))
        ]


{-| The column whose cell is the row's one handle. The client models an overview row as a single
object -- a click anywhere in it selects that object, a right-click opens its menu -- so the row
has exactly one thing to act on, not one per cell. That handle goes on the name, which is already
the row's identity; where the client's language leaves us no `Name` column, it falls to the first
column so the row is still actionable. There is no separate actions column: the columns are for
comparing objects, and the object itself is the name.
-}
handleColumn : List String -> Maybe String
handleColumn headers =
    if List.member "Name" headers then
        Just "Name"

    else
        List.head headers


captionText : List OverviewWindowEntry -> String
captionText entries =
    case List.length entries of
        0 ->
            "Overview, empty"

        1 ->
            "Overview, 1 object"

        count ->
            "Overview, " ++ String.fromInt count ++ " objects"


rowHtml : Context event -> Maybe String -> List String -> OverviewWindowEntry -> Html.Html event
rowHtml context handleColumnName headers entry =
    Html.tr (backgroundAttributes entry) (headers |> List.map (cellHtml context handleColumnName entry))


{-| The cell for one column of one entry.

The handle column's cell is the row's header (`th scope="row"`) and carries the one control, so
moving down another column -- the usual way to find the nearest thing, or the fastest -- is
announced against the object it belongs to, and that same cell is where the row is acted on. A
click on it selects the object, the context-menu gesture opens its menu; both target the whole
row's node, which is how the client itself resolves a click anywhere in the row.

The `"Name"` key is the client's own English column name, and is the same key
`ParseUserInterface` reads `objectName` from; on a client running in another language the handle
falls to the first column instead. Treat that as debt, in the sense of `CONVENTIONS.md` rule 4.

-}
cellHtml : Context event -> Maybe String -> OverviewWindowEntry -> String -> Html.Html event
cellHtml context handleColumnName entry header =
    let
        value =
            entry.cellsTexts
                |> Dict.get header
                |> Maybe.withDefault ""
                |> Common.plainText
    in
    if Just header == handleColumnName then
        Html.th [ HA.scope "row" ] [ Common.controlElement context.inputRoute value entry.uiNode True ]

    else
        Html.td [] [ Html.text value ]


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
