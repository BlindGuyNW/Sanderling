module Frontend.View.GenericWindow exposing (view)

{-| Presents a window of the game client without knowing what kind of window it is.

Every window the client builds carries a caption, header buttons the client labels with tooltips,
and content nodes that carry text. That is enough to read a window and click things in it, so a
window we have never written a specialized view for is still usable the day the client shows it,
rather than being invisible until someone adds a parse function for it.

The hard part is not finding the text -- it is deciding how much of the tree is *one thing*.
Taking every descendant that carries text and making each an entry, which is what this used to do,
reads the same thing several times over and offers buttons on almost none of them. One navigation
entry in the Agency window is a node carrying the entry's own text wrapped around two `TextBody`
children holding the count and the name, so "Agent Missions" arrived three times: once as the
entry, once as the count `4`, once as the name again -- and two of those three carried an Activate
and a Menu button that do nothing, because they are labels inside a control rather than controls.

So the walk below stops at the first node that looks like something the player acts on, takes the
whole of its text as that one thing's label, and does not descend into it. What is left over is
prose, and prose gets no buttons.

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


{-| How much text will be joined into one line before the walk gives up and leaves it in pieces.

Merging is what stops a window reading as a column of fragments, but merged without limit it turns
a page of prose into a single unskippable paragraph. Past this length the pieces are worth more
than the sentence.

-}
maximumMergedProseLength : Int
maximumMergedProseLength =
    200


{-| What one step of the walk found.

A `Group` is a heading the client itself drew over the entries that follow it, so the page can
nest them under it instead of running them together.

`Prose` and `Control` are told apart here but presented as one list, so the page does not
alternate between a bulleted indented run and a flush-left unbulleted one. Prose keeps the
position it was read from, because merging it back together has to put it in the order it appears
on screen rather than the order its containers happened to be visited in.

-}
type ContentItem
    = Group String
    | Prose ProseText
    | Control Common.Entry


{-| A piece of text, and where on screen it came from.

The position is what makes merging honest. Sorting containers and then concatenating what each
returned gives the order of the containers, not of the words: the Agency window puts the headline
`Monthly Track` and the line `Monthly Track Expires in 9d...` in separate containers whose
rectangles are not in the same order as the text inside them, and the merge read the expiry first.

-}
type alias ProseText =
    { text : String
    , position : ( Int, Int )
    }


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

        allItems =
            contentItems window

        shownItems =
            allItems |> List.take maximumNumberOfContentEntries

        numberNotShown =
            List.length allItems - List.length shownItems

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
        ++ (if shownItems == [] then
                [ Common.textLines [ "Nothing readable in this window." ] ]

            else
                groupedHtml context shownItems ++ notShownHtml
           )


{-| Lays the items out, opening a section wherever the client drew a heading.

Items before the first heading belong to the window itself rather than to any group, so they are
presented at the current level instead of being pushed under a heading we invented for them.

-}
groupedHtml : Context event -> List ContentItem -> List (Html.Html event)
groupedHtml context items =
    let
        ( leading, groups ) =
            splitIntoGroups items
    in
    runHtml context leading
        ++ (groups
                |> List.map
                    (\( title, groupItems ) ->
                        Common.section context title (\inner -> runHtml inner groupItems)
                    )
           )


{-| The items up to the first heading, and then each heading with the items that follow it.
-}
splitIntoGroups : List ContentItem -> ( List ContentItem, List ( String, List ContentItem ) )
splitIntoGroups items =
    let
        step item ( leading, groups ) =
            case ( item, groups ) of
                ( Group title, _ ) ->
                    ( leading, ( title, [] ) :: groups )

                ( _, [] ) ->
                    ( item :: leading, [] )

                ( _, ( title, groupItems ) :: rest ) ->
                    ( leading, ( title, item :: groupItems ) :: rest )
    in
    items
        |> List.foldl step ( [], [] )
        |> (\( leading, groups ) ->
                ( List.reverse leading
                , groups |> List.reverse |> List.map (Tuple.mapSecond List.reverse)
                )
           )


{-| A run of items with no heading between them, as one list.

One list, not one per kind: a screen reader announces the count once and then reads straight down
it, and every item sits at the same indent whether or not it has buttons.

-}
runHtml : Context event -> List ContentItem -> List (Html.Html event)
runHtml context items =
    case items |> List.filterMap entryOfItem of
        [] ->
            []

        entries ->
            [ Common.actionList context entries ]


entryOfItem : ContentItem -> Maybe Common.Entry
entryOfItem item =
    case item of
        Control entry ->
            Just entry

        Prose prose ->
            Just { label = prose.text, actions = [] }

        Group _ ->
            Nothing


contentItems : GenericWindow -> List ContentItem
contentItems window =
    case window.contentNode of
        Nothing ->
            []

        Just contentNode ->
            itemsFromNode contentNode


{-| Walks a node, stopping at whatever the player acts on.

Descending is the default, so a container we do not recognise still gives up everything inside
it. Only a node that is itself a control ends the walk, and only for its own subtree.

-}
itemsFromNode : UITreeNodeWithDisplayRegion -> List ContentItem
itemsFromNode node =
    if not (Common.isVisible node) then
        []

    else if isGroupHeading node then
        case textOfSubtree node of
            Nothing ->
                []

            Just title ->
                [ Group title ]

    else if isInteractiveUnit node then
        case textOfSubtree node of
            Nothing ->
                []

            Just label ->
                [ Control { label = label, actions = [ Common.activate node, Common.menu node ] } ]

    else
        let
            fromChildren =
                node
                    |> EveOnline.ParseUserInterface.listChildrenWithDisplayRegion
                    |> Common.nodesInReadingOrder
                    |> List.concatMap itemsFromNode
        in
        case ( fromChildren, ownText node ) of
            ( [], Just text ) ->
                [ Prose { text = text, position = positionOfNode node } ]

            _ ->
                mergeProseRuns fromChildren


positionOfNode : UITreeNodeWithDisplayRegion -> ( Int, Int )
positionOfNode node =
    ( node.totalDisplayRegion.y, node.totalDisplayRegion.x )


{-| Joins neighbouring prose into a single line.

The client lays a lot of its content out as a grid of small text nodes -- a tier of rewards is
eight cells reading `3,000`, `1,500`, `SKINR`, `SKINR`, `5`, `8,000,000`, `150,000`, `75,000`.
One per line, each is a fragment with nothing to attach it to, and the player has to sit through
eight of them to learn there was nothing there worth stopping for. Joined, they are one line that
can be skipped in one keystroke.

Runs are joined rather than whole containers, so prose still comes together when it sits beside
something with buttons. A daily goal is a card holding its reward buttons alongside the lines
`Daily Goal`, `0 / 50` and `Earn 50 LP for any corporation`; requiring the whole card to be prose
left those three stranded on separate lines because the buttons were their siblings.

A heading always ends a run: it marks the start of something new, and text either side of it
belongs to different things.

-}
mergeProseRuns : List ContentItem -> List ContentItem
mergeProseRuns items =
    items
        |> groupConsecutiveProse
        |> List.concatMap
            (\group ->
                case group of
                    ProseRun texts ->
                        mergedProse texts

                    Other item ->
                        [ item ]
            )


type ProseGroup
    = ProseRun (List ProseText)
    | Other ContentItem


groupConsecutiveProse : List ContentItem -> List ProseGroup
groupConsecutiveProse items =
    items
        |> List.foldl
            (\item groups ->
                case ( item, groups ) of
                    ( Prose prose, (ProseRun run) :: rest ) ->
                        ProseRun (prose :: run) :: rest

                    ( Prose prose, _ ) ->
                        ProseRun [ prose ] :: groups

                    _ ->
                        Other item :: groups
            )
            []
        |> List.reverse
        |> List.map
            (\group ->
                case group of
                    ProseRun run ->
                        ProseRun (List.reverse run)

                    other ->
                        other
            )


{-| One run of prose, in the order it appears on screen.

Sorting by position here, rather than trusting the order the walk produced, is what keeps a
headline in front of the line that qualifies it.

-}
mergedProse : List ProseText -> List ContentItem
mergedProse texts =
    let
        ordered =
            texts |> List.sortBy .position

        joined =
            ordered |> List.map .text |> String.join ", "
    in
    if List.length ordered < 2 || maximumMergedProseLength < String.length joined then
        ordered |> List.map Prose

    else
        case ordered |> List.head of
            Nothing ->
                []

            Just first ->
                [ Prose { text = joined, position = first.position } ]


{-| A heading the client drew over the entries below it.

The client names these by ending the type with `HeaderEntry`, or by carrying `Header` in the type
of a node that holds nothing but text. Checked before `isInteractiveUnit`, because every one of
these also matches "ends in Entry".

Observed in the Agency window on 2026-07-22: `SideNavigationHeaderEntry` carrying `Features`,
`Career Paths` and `Other Tags`, each standing over the entries that follow it.

-}
isGroupHeading : UITreeNodeWithDisplayRegion -> Bool
isGroupHeading node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName
    in
    String.contains "HeaderEntry" typeName


{-| Something the player acts on, whose insides are its label rather than things of their own.

This is shaped from the type the client builds the control as, rather than from a table of names,
so it keeps working when the client gains a kind of control nobody here has seen. Getting it wrong
in the generous direction costs a button that does nothing; getting it wrong in the strict
direction costs the player the only way to act on something, so it leans generous.

Carrying a tooltip is deliberately *not* part of this. A tooltip means the client has something to
say about a node, not that there is anything to do to it -- the same distinction `CONVENTIONS.md`
rule 6 draws when it says a tooltip is not content. Treating it as a control marker put Activate
and Menu on the daily-bonus gauge in the Agency window, whose `_hint` reads "Complete two goals on
the same day and earn unallocated skill points as an added bonus". That is an explanation, and the
gauge showing `0/2` is not a button. Observed 2026-07-22.

The header buttons a window carries are found by their tooltips, but that happens in
`parseGenericWindow` and reaches the page by a different path, so they are unaffected.

-}
isInteractiveUnit : UITreeNodeWithDisplayRegion -> Bool
isInteractiveUnit node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName
    in
    List.any (\marker -> String.contains marker typeName)
        [ "Entry", "Button", "MenuItem", "Tab", "Checkbox", "Radio" ]


{-| All the text inside a node, as one label.

Repeats are dropped wherever they fall, not only where they land next to each other. The client
puts the same string on a control and again on the label inside it, and once the texts are in
reading order those two copies are usually separated by something else -- a navigation entry
reads `Agent Missions`, `4`, `Agent Missions`, because the count sits between the wrapper and the
label. Dropping only neighbours would leave both copies in.

-}
textOfSubtree : UITreeNodeWithDisplayRegion -> Maybe String
textOfSubtree node =
    node
        |> EveOnline.ParseUserInterface.getAllContainedDisplayTextsWithRegion
        |> List.sortBy (Tuple.second >> .totalDisplayRegion >> (\region -> ( region.y, region.x )))
        |> List.map Tuple.first
        |> List.filterMap EveOnline.ParseUserInterface.discardUnreadableText
        |> List.map Common.plainText
        |> List.filter (String.isEmpty >> not)
        |> dropDuplicates
        |> (\texts ->
                if texts == [] then
                    Nothing

                else
                    Just (String.join ", " texts)
           )


{-| The text a node carries itself, ignoring anything its children carry.
-}
ownText : UITreeNodeWithDisplayRegion -> Maybe String
ownText node =
    node.uiNode
        |> EveOnline.ParseUserInterface.getDisplayText
        |> Maybe.map Common.plainText
        |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
        |> Maybe.andThen
            (\text ->
                if String.isEmpty text then
                    Nothing

                else
                    Just text
            )


{-| Keeps the first occurrence of each text and drops every later one.
-}
dropDuplicates : List String -> List String
dropDuplicates texts =
    texts
        |> List.foldl
            (\text kept ->
                if List.member text kept then
                    kept

                else
                    text :: kept
            )
            []
        |> List.reverse
