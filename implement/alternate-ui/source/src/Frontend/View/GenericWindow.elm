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

import Dict
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


view : Dict.Dict String (List String) -> Context event -> GenericWindow -> Html.Html event
view typeHierarchy context window =
    Common.section context (titleForWindow window) (bodyHtml typeHierarchy window)


titleForWindow : GenericWindow -> String
titleForWindow window =
    case window.caption of
        Just caption ->
            caption

        Nothing ->
            case window.name of
                Just name ->
                    handWrittenNames name |> Maybe.withDefault name

                Nothing ->
                    window.typeName


{-| Names for the nodes whose label the client only supplies on hover, so a reading finds nothing
to call them by except their internal `_name`. The debt `CONVENTIONS.md` rule 4 describes: each
entry is a claim observed on a real client, English-only, and comes out as soon as the client is
seen to supply the name itself.

The station service buttons and `lobbyWnd` were observed docked on 2026-07-21; `agentChatBtn`
in the station window's Agents panel on 2026-07-23.

-}
handWrittenNames : String -> Maybe String
handWrittenNames name =
    case name of
        "lobbyWnd" ->
            Just "Station"

        "agentChatBtn" ->
            Just "Start Conversation"

        "charcustomization" ->
            Just "Character Customization"

        "fitting" ->
            Just "Fitting"

        "industry" ->
            Just "Industry"

        "insurance" ->
            Just "Insurance"

        "lpstore" ->
            Just "LP Store"

        "market" ->
            Just "Market"

        "medical" ->
            Just "Medical"

        "navyoffices" ->
            Just "Navy Offices"

        "repairshop" ->
            Just "Repair Shop"

        "reprocessingPlant" ->
            Just "Reprocessing Plant"

        _ ->
            Nothing


bodyHtml : Dict.Dict String (List String) -> GenericWindow -> Context event -> List (Html.Html event)
bodyHtml typeHierarchy window context =
    let
        headerButtonEntries =
            window.headerButtons
                |> List.filter (.uiNode >> Common.isVisible)
                |> Common.inReadingOrder
                |> List.map
                    (\button ->
                        Common.controlActivateOnly
                            (Common.labelForControl Common.noNameTable button.uiNode)
                            button.uiNode
                    )

        allItemLists =
            contentItemLists typeHierarchy window

        shownItemLists =
            allItemLists |> takeAcrossLists maximumNumberOfContentEntries

        numberNotShown =
            (allItemLists |> List.map List.length |> List.sum)
                - (shownItemLists |> List.map List.length |> List.sum)

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
        ++ (if List.all List.isEmpty shownItemLists then
                [ Common.textLines [ "Nothing readable in this window." ] ]

            else
                (shownItemLists |> List.concatMap (groupedHtml context)) ++ notShownHtml
           )


{-| The cap on shown entries, applied across the content parts in order, so the count the cutoff
message reports stays one number for the whole window.
-}
takeAcrossLists : Int -> List (List a) -> List (List a)
takeAcrossLists limit lists =
    lists
        |> List.foldl
            (\list ( kept, remaining ) ->
                ( List.take remaining list :: kept, max 0 (remaining - List.length list) )
            )
            ( [], limit )
        |> Tuple.first
        |> List.reverse


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
            Just (Common.prose prose.text)

        Group _ ->
            Nothing


{-| The window's content, one item list per content part.

The parts stay separate through grouping: a window without a `main` node -- the settings window --
has its content split into a center panel and a bottom button bar, and running them together would
file `Return to Game` under whatever section heading the panel happened to end with.

-}
contentItemLists : Dict.Dict String (List String) -> GenericWindow -> List (List ContentItem)
contentItemLists typeHierarchy window =
    window.contentNodes
        |> Common.nodesInReadingOrder
        |> List.map (walk typeHierarchy >> .items)


{-| What a walk of one node found, and whether any of its subtree was a control candidate.

`hasCandidate` is what makes over-generous candidate detection safe. A candidate that contains
another candidate is usually not a control but the container of one -- a `ButtonGroup` holding
two `Button`s, a `CardsContainer` holding cards -- so it is descended into rather than read as a
single control. Deciding that from the children's results is exactly what `hasCandidate` carries
up. Usually, not always: the station's agent cards are genuine controls that hold their own chat
button, so a demoted candidate with text of its own is brought back as a card by `cardItems`.

It also drives the text collapse below: a node is only offered as one all-text control when
nothing beneath it was a candidate, so a section of prose is not mistaken for a button.

-}
type alias WalkResult =
    { items : List ContentItem
    , hasCandidate : Bool
    }


walk : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> WalkResult
walk typeHierarchy node =
    if not (Common.isVisible node) then
        { items = [], hasCandidate = False }

    else if isGroupHeading node then
        { items = textOfSubtree node |> Maybe.map (Group >> List.singleton) |> Maybe.withDefault []
        , hasCandidate = True
        }

    else
        case sliderEntry typeHierarchy node of
            Just entry ->
                { items = [ Control entry ], hasCandidate = True }

            Nothing ->
                --  Before the container logic, which would get a filled field wrong: the clear-X
                --  ButtonIcon the client grows inside a field that holds text is a candidate,
                --  and seen by the container walk it demotes the field to a card -- a button
                --  labeled with whatever was last typed. Observed on the market window's search
                --  field, 2026-07-23.
                case textFieldItems typeHierarchy node of
                    Just entries ->
                        { items = entries |> List.map Control, hasCandidate = True }

                    Nothing ->
                        walkContainer typeHierarchy node


walkContainer : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> WalkResult
walkContainer typeHierarchy node =
    let
            childResults =
                node
                    |> EveOnline.ParseUserInterface.listChildrenWithDisplayRegion
                    |> Common.nodesInReadingOrder
                    |> List.map (walk typeHierarchy)

            childItems =
                childResults |> List.concatMap .items

            descendantHasCandidate =
                childResults |> List.any .hasCandidate

            nodeIsCandidate =
                isControlCandidate typeHierarchy node

            walkResultBeforeScrollControls =
                walkContainerItems typeHierarchy node childItems descendantHasCandidate nodeIsCandidate
        in
        if Common.isScrollingContainer typeHierarchy node then
            case moreEntriesControls node of
                ( [], [] ) ->
                    walkResultBeforeScrollControls

                ( aboveControls, belowControls ) ->
                    { items = aboveControls ++ walkResultBeforeScrollControls.items ++ belowControls
                    , hasCandidate = True
                    }

        else
            walkResultBeforeScrollControls


walkContainerItems : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> List ContentItem -> Bool -> Bool -> WalkResult
walkContainerItems typeHierarchy node childItems descendantHasCandidate nodeIsCandidate =
        if nodeIsCandidate && not descendantHasCandidate then
            --  A candidate with no candidate inside it is the control itself; its whole subtree
            --  is its label, and we do not descend past it. A control with no text at all is
            --  still a control -- the station service buttons are icon-only -- so it falls back
            --  to the client's tooltip or its internal name rather than being dropped.
            let
                label =
                    textOfSubtree node
                        |> Maybe.withDefault (Common.labelForControl handWrittenNames node)

                entry =
                    case checkboxState typeHierarchy node of
                        Just checked ->
                            Common.toggleControl label checked node

                        Nothing ->
                            Common.control label node
            in
            { items = [ Control entry ]
            , hasCandidate = True
            }

        else if nodeIsCandidate then
            --  A candidate holding candidates is one of two things, told apart by whether any
            --  text is left once its inner controls have claimed theirs. See `cardItems`.
            case cardItems node childItems of
                Just items ->
                    { items = items, hasCandidate = True }

                Nothing ->
                    { items = mergeProseRuns childItems, hasCandidate = True }

        else if descendantHasCandidate then
            --  A plain container with controls somewhere below: keep what the children found.
            { items = mergeProseRuns childItems, hasCandidate = True }

        else
            case collapsedControlForNode node childItems of
                Just item ->
                    { items = [ item ], hasCandidate = False }

                Nothing ->
                    case ( childItems, ownText node ) of
                        ( [], Just text ) ->
                            { items = [ Prose { text = text, position = positionOfNode node } ]
                            , hasCandidate = False
                            }

                        _ ->
                            { items = mergeProseRuns childItems, hasCandidate = False }


{-| The "Show more entries" controls a scrolling list grows at whichever of its ends the content
continues past, as `(above, below)`.

Two situations put content past the viewport, and these controls serve both. Content the client
has built but scrolled out of place is reachable by an ordinary click, which scrolls it into view
first. But a long list is *virtualized*: the client only builds nodes for the rows near the
viewport, so the rows beyond it are not in the reading at all -- nothing to list, nothing to
click. Observed in the overview settings window on 2026-07-23: a preset list 1524 px tall held
nodes for only the 11 rows in its 269 px viewport. The only way to the rest is to make the client
scroll, which makes it build the next rows; pressing one of these scrolls by a page, and the page
picks the new rows up with its next reading.

The content extent is measured over the built descendants, or from the client's own `__content`
sizing node where there is one -- in the observed window that node carries the full 1524 px
height even though most rows do not exist.

-}
moreEntriesControls : UITreeNodeWithDisplayRegion -> ( List ContentItem, List ContentItem )
moreEntriesControls scrollNode =
    let
        region =
            scrollNode.totalDisplayRegion

        descendantRegions =
            scrollNode
                |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                |> List.map .totalDisplayRegion

        contentTop =
            descendantRegions |> List.map .y |> List.minimum |> Maybe.withDefault region.y

        contentBottom =
            descendantRegions
                |> List.map (\descendantRegion -> descendantRegion.y + descendantRegion.height)
                |> List.maximum
                |> Maybe.withDefault (region.y + region.height)

        --  Less than a row's height past the edge is rounding, not more content.
        threshold =
            30
    in
    ( if contentTop < region.y - threshold then
        [ Control (Common.pageControl "Show more entries above" -1 scrollNode) ]

      else
        []
    , if region.y + region.height + threshold < contentBottom then
        [ Control (Common.pageControl "Show more entries below" 1 scrollNode) ]

      else
        []
    )


{-| A candidate that holds other candidates, re-read as a card when text remains its own.

The demotion in `walk` assumed no genuine control ever contains another candidate, which held
for the Agency and fitting windows -- and then the station's Agents panel disproved it: an
`AgentEntry` is a card the player right-clicks for its menu, and it holds a chat `ButtonIcon`.
Demoting it turned the agent rows into unclickable prose. Observed 2026-07-23.

What separates a card from a mere container of controls is whether any text is left over once
the inner controls have claimed theirs. A `ButtonGroup` holding two `Button`s has none -- every
word in it belongs to one of the buttons -- so it stays a container, and no phantom control
appears. The agent card keeps its name, career and mission status, and that leftover text names
the thing the row acts on, so the row comes back as a control followed by its inner controls.

Past the merge limit the leftover text is a page of prose rather than a card's label, and the
node stays a container, the same cutoff `collapsedControlForNode` applies.

-}
cardItems : UITreeNodeWithDisplayRegion -> List ContentItem -> Maybe (List ContentItem)
cardItems node childItems =
    let
        unclaimedTexts =
            childItems
                |> List.filterMap
                    (\item ->
                        case item of
                            Prose prose ->
                                Just prose

                            _ ->
                                Nothing
                    )
                |> List.sortBy .position
                |> List.map .text

        innerControlsAndGroups =
            childItems
                |> List.filter
                    (\item ->
                        case item of
                            Prose _ ->
                                False

                            _ ->
                                True
                    )

        label =
            String.join ", " unclaimedTexts
    in
    if String.isEmpty label || maximumMergedProseLength < String.length label then
        Nothing

    else
        Just (Control (Common.control label node) :: innerControlsAndGroups)


{-| A container holding nothing but text is itself one thing the player can act on.

`isInteractiveUnit` recognises a control by the type the client built it as, which means it only
knows the kinds of control someone has already seen. That list was wrong about the Agency window's
mission cards: an `AgentMissionCard` holds only text, matched none of the markers, and so came out
as prose with no buttons -- which took away the only route to its right-click menu, and that menu
is where `Start Conversation` lives. Accepting a mission was unreachable. Observed 2026-07-22.

So rather than rely on having named every type, treat the shape as a second signal. A container
whose whole subtree is text is a leaf as far as the player is concerned, and in this client that is
almost always a card, a row or a tile -- something with a right-click menu, because in EVE
right-click acts on a region rather than on a widget. Offering the menu costs an entry that may do
nothing; not offering it costs the player the action entirely, and rule 1a is clear about which way
that trade goes.

Only containers collapse. A lone text node stays prose, or every label on the page would sprout a
pair of buttons -- which is the noise this whole walk exists to remove.

Past the merge limit the container is a page of text rather than a card, so it keeps its separate
lines instead.

-}
collapsedControlForNode : UITreeNodeWithDisplayRegion -> List ContentItem -> Maybe ContentItem
collapsedControlForNode node childItems =
    if List.isEmpty childItems then
        Nothing

    else
        case textOfSubtree node of
            Nothing ->
                Nothing

            Just label ->
                if maximumMergedProseLength < String.length label then
                    Nothing

                else
                    Just (Control (Common.control label node))


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

Observed in the settings window on 2026-07-23: `SystemMenuHeader`, a container wrapping the
`TextHeader` the client draws over each settings section -- Display, Effects, Graphic Content
Settings. Matched by its exact type: `TextHeader` alone cannot be the signal, because the same
type is also the label inside the clickable `TreeViewEntryHeader` category rows.

-}
isGroupHeading : UITreeNodeWithDisplayRegion -> Bool
isGroupHeading node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName
    in
    String.contains "HeaderEntry" typeName
        || (typeName == "SystemMenuHeader")


{-| Something the player acts on, whose insides are its label rather than things of their own.

Three independent signals, in order of how much we trust them:

1.  **Inheritance.** The client builds each widget from a class, and stores that class's ancestry.
    `TrackJobButton` derives from `Button`; `ButtonGroup` and `ButtonWrapper` do not -- they are
    the container and the wrapper around it. The name cannot tell those apart (`ButtonUnderlay`,
    decoration, also contains "Button"), and an earlier substring test on the name got this exactly
    wrong: it flagged the underlay, which made the real button look like a container and demoted it,
    so `Track` and `Start Conversation` collapsed into one dead line. Matching a *family root* in
    the inheritance chain, by identity, catches the button and excludes the group, the wrapper and
    the underlay. `familyRootsOfControls` is that set of base classes.

2.  **A link.** A `Link` object, or text carrying the client's own `<a href>` / `<url=>` / `<url:>`
    markup, is a handle to a game object -- a system, a station, an agent -- and the client makes
    each its own node. Left-click shows the object, right-click opens its menu, exactly as for any
    other control, so a link is one of these.

3.  **An exact type name.** A few controls -- `GroupAllButton`, `SidePanelButton` -- derive straight
    from `Container` with no distinctive base, so inheritance cannot find them. They are named
    individually, matched by equality. Never by substring: that is what broke signal 1.

Getting this wrong in the generous direction costs a control that does nothing; getting it wrong in
the strict direction costs the player the only way to act on something, so it leans generous. A
node that holds another candidate is demoted to a container by `walk`, which is what keeps the
generosity safe.

Carrying a tooltip is deliberately *not* a signal. A tooltip means the client has something to say
about a node, not that there is anything to do to it -- the same distinction `CONVENTIONS.md` rule 6
draws. Treating it as one put actions on the daily-bonus gauge in the Agency window, whose `_hint`
explains the bonus; the gauge showing `0/2` is not a button. Observed 2026-07-22.

Treat `familyRootsOfControls` and `controlTypeNames` as the debt `CONVENTIONS.md` rule 4 describes:
each is a claim about how the client names its classes, and each will need revisiting -- but a claim
about a base class the client itself defines, matched by identity, not a guess at a substring.

-}
isControlCandidate : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> Bool
isControlCandidate typeHierarchy node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName

        inheritanceChain =
            Dict.get typeName typeHierarchy |> Maybe.withDefault [ typeName ]
    in
    isLinkNode node
        || List.member typeName controlTypeNames
        || List.any (\root -> List.member root inheritanceChain) familyRootsOfControls


{-| The client base classes that mark a family of controls, matched anywhere in a type's ancestry.
These are classes the client itself defines; a new leaf type in one of these families is caught
with no change here. Observed in the Agency and fitting windows, 2026-07-22.
-}
familyRootsOfControls : List String
familyRootsOfControls =
    [ "Button" -- ordinary buttons, and TrackJobButton, MenuButton, ...
    , "BaseNeocomButton" -- the neocom sidebar buttons, none of which derive from Button
    , "LeftSideButton" -- the in-space ship control buttons
    , "ButtonIcon" -- icon-only buttons: filters, close/minimize, ...
    , "Tab" -- window tabs of every kind
    , "JobCard" -- Agency mission / campaign / daily-goal cards
    , "SE_BaseClassCore" -- scroll-list entries: overview rows, chat entries, ship lists
    , "SideNavigationEntryInterface" -- side-navigation entries
    , "FittingSlotBase" -- the module slots in the fitting window
    , "BaseToggleButtonGroupButton" -- toggle buttons, e.g. the fitting hull/module/charge switch
    , "BaseSingleLineEdit" -- single-line text fields, e.g. a search box
    , "Combo" -- dropdown selectors: SystemMenuCombo in the settings window; opens its options as a menu
    , "Checkbox" -- labelled checkboxes, e.g. the settings window's effects toggles
    , "TreeViewEntry" -- tree navigation rows; TreeViewEntryHeader, the settings category list, derives from it
    ]


{-| Controls the client builds straight from `Container` with no distinctive base, so inheritance
cannot find them. Matched by equality, never substring -- `ButtonUnderlay` is decoration, and a
substring test on "Button" wrongly claims it, which demotes the real button that contains it.
-}
controlTypeNames : List String
controlTypeNames =
    [ "GroupAllButton", "SidePanelButton", "ExpandButton", "SafetyButton", "ModuleButton" ]


{-| The node read as a slider, when it is one: a node that is, or directly holds, a track of the
client's `Slider` family. The wrappers are not `Slider` subclasses -- `SystemMenuSlider` in the
settings window derives from `ContainerAutoSize` and holds the label and the `Slider` track side
by side -- so the unit to present is the wrapper, whose subtree text is the slider's label.

The client stores no readable value on the node; the value lives only in geometry, the `handle`'s
position along the track. Observed in the settings window's Audio panel on 2026-07-23, where the
computed percentages matched the client's own display across thirteen sliders.

The entry targets the track node, and setting a value is a click at that fraction of the track's
width: the client jumps the handle to the clicked position (verified live on `masterVolume`).

-}
sliderEntry : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> Maybe Common.Entry
sliderEntry typeHierarchy node =
    let
        isSliderTrack candidate =
            let
                typeName =
                    candidate.uiNode.pythonObjectTypeName

                inheritanceChain =
                    Dict.get typeName typeHierarchy |> Maybe.withDefault [ typeName ]
            in
            List.member "Slider" inheritanceChain

        maybeTrack =
            if isSliderTrack node then
                Just node

            else
                node
                    |> EveOnline.ParseUserInterface.listChildrenWithDisplayRegion
                    |> List.filter isSliderTrack
                    |> List.head
    in
    maybeTrack
        |> Maybe.andThen
            (\track ->
                track
                    |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                    |> List.filter
                        (.uiNode
                            >> EveOnline.ParseUserInterface.getNameFromDictEntries
                            >> (==) (Just "handle")
                        )
                    |> List.head
                    |> Maybe.andThen
                        (\handle ->
                            let
                                trackRegion =
                                    track.totalDisplayRegion

                                handleTravel =
                                    trackRegion.width - handle.totalDisplayRegion.width
                            in
                            if handleTravel <= 0 then
                                Nothing

                            else
                                Just
                                    (Common.sliderControl
                                        (textOfSubtree node
                                            |> Maybe.withDefault (Common.labelForControl handWrittenNames node)
                                        )
                                        (clamp 0
                                            100
                                            (round
                                                (100
                                                    * toFloat (handle.totalDisplayRegion.x - trackRegion.x)
                                                    / toFloat handleTravel
                                                )
                                            )
                                        )
                                        track
                                    )
                        )
            )


{-| The entries for a text field -- a node of the client's `BaseSingleLineEdit` family -- or
`Nothing` for anything else. The field renders as an edit box: type into it and press Enter, and
the typed text replaces the field's content in the game client. Verified against the market
window's search field on a live client, 2026-07-23.

The client builds these fields with a `textLabel` child holding the current content and a
`hintTextLabel` holding the placeholder, drawn only while the field is empty. That makes the
usual label preference wrong in the filled state: the text such a node "contains" is whatever
the player last typed, which names nothing. So the label is the placeholder while the client
shows one, and falls back past contained text straight to the client's tooltip or internal name.

A field that holds text also grows controls of its own -- a clear-X `ButtonIcon`, carrying the
client's `Clear` tooltip -- which is why the whole subtree is claimed here rather than left to
the container walk: seen there, the inner candidate demotes the field to a card, a button
labeled with whatever was last typed. The inner controls follow the field as entries of their
own, so the X stays a button the player can press.

-}
textFieldItems : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> Maybe (List Common.Entry)
textFieldItems typeHierarchy node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName

        inheritanceChain =
            Dict.get typeName typeHierarchy |> Maybe.withDefault [ typeName ]
    in
    if not (List.member "BaseSingleLineEdit" inheritanceChain) then
        Nothing

    else
        let
            textOfDescendantNamed name =
                node
                    |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                    |> List.filter
                        (.uiNode
                            >> EveOnline.ParseUserInterface.getNameFromDictEntries
                            >> (==) (Just name)
                        )
                    |> List.filterMap (.uiNode >> EveOnline.ParseUserInterface.getDisplayText)
                    |> List.head
                    |> Maybe.map Common.plainText
                    |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText

            label =
                [ textOfDescendantNamed "hintTextLabel"
                , node.uiNode
                    |> EveOnline.ParseUserInterface.getHintTextFromDictEntries
                    |> Maybe.map Common.plainText
                    |> Maybe.andThen EveOnline.ParseUserInterface.discardUnreadableText
                , node.uiNode |> EveOnline.ParseUserInterface.getNameFromDictEntries
                ]
                    |> List.filterMap identity
                    |> List.head
                    |> Maybe.withDefault "(text field)"

            innerControls =
                node
                    |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                    |> List.filter (isControlCandidate typeHierarchy)
                    |> List.filter Common.isVisible
                    |> Common.nodesInReadingOrder
                    |> List.map
                        (\inner ->
                            Common.control (Common.labelForControl handWrittenNames inner) inner
                        )
        in
        Just
            (Common.textFieldControl label (textOfDescendantNamed "textLabel") node
                :: innerControls
            )


{-| The on/off state the client draws on a `Checkbox`, or `Nothing` for anything that is not one.

Checked is the presence of a sprite named `self_ok` in the checkbox's subtree; unchecked, the
client removes the sprite entirely rather than hiding it. The same marking as
`MenuEntryViewCheckbox` uses in context menus. Absence only means unchecked on a node of the
Checkbox family, so everything else gets no state at all.

Observed in the settings window on 2026-07-23: the ten enabled effects checkboxes each carried
the sprite, the two disabled character-display ones did not, matching the client's own display.

-}
checkboxState : Dict.Dict String (List String) -> UITreeNodeWithDisplayRegion -> Maybe Bool
checkboxState typeHierarchy node =
    let
        typeName =
            node.uiNode.pythonObjectTypeName

        inheritanceChain =
            Dict.get typeName typeHierarchy |> Maybe.withDefault [ typeName ]
    in
    if List.member "Checkbox" inheritanceChain then
        Just
            (node
                |> EveOnline.ParseUserInterface.listDescendantsWithDisplayRegion
                |> List.any
                    (.uiNode
                        >> EveOnline.ParseUserInterface.getNameFromDictEntries
                        >> (==) (Just "self_ok")
                    )
            )

    else
        Nothing


{-| A `Link` object, or text carrying the client's own link markup. The markup is checked before it
is stripped for display, and takes any of the three forms the client emits.
-}
isLinkNode : UITreeNodeWithDisplayRegion -> Bool
isLinkNode node =
    (node.uiNode.pythonObjectTypeName == "Link")
        || (case EveOnline.ParseUserInterface.getDisplayText node.uiNode of
                Nothing ->
                    False

                Just rawText ->
                    [ "<a href=", "<url=", "<url:" ]
                        |> List.any (\marker -> String.contains marker rawText)
           )


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
