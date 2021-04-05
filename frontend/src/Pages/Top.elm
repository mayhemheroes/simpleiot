module Pages.Top exposing (Model, Msg, Params, page)

import Api.Auth exposing (Auth)
import Api.Data as Data exposing (Data)
import Api.Node as Node exposing (Node)
import Api.Point as Point exposing (Point)
import Api.Port as Port
import Api.Response exposing (Response)
import Browser.Navigation exposing (Key)
import Components.NodeAction as NodeAction
import Components.NodeCondition as NodeCondition
import Components.NodeDevice as NodeDevice
import Components.NodeGroup as NodeGroup
import Components.NodeMessageService as NodeMessageService
import Components.NodeModbus as NodeModbus
import Components.NodeModbusIO as NodeModbusIO
import Components.NodeRule as NodeRule
import Components.NodeUser as NodeUser
import Components.NodeVariable as NodeVariable
import Element exposing (..)
import Element.Input as Input
import Http
import List.Extra
import Shared
import Spa.Document exposing (Document)
import Spa.Generated.Route as Route
import Spa.Page as Page exposing (Page)
import Spa.Url exposing (Url)
import Task
import Time
import Tree exposing (Tree)
import Tree.Zipper as Zipper exposing (Zipper)
import UI.Button as Button
import UI.Form as Form
import UI.Icon as Icon
import UI.Style as Style exposing (colors)
import UI.ViewIf exposing (viewIf)
import Utils.Route


page : Page Params Model Msg
page =
    Page.application
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        , save = save
        , load = load
        }



-- INIT


type alias Params =
    ()


type alias Model =
    { key : Key
    , nodeEdit : Maybe NodeEdit
    , zone : Time.Zone
    , now : Time.Posix
    , nodes : Maybe (Tree NodeView)
    , auth : Auth
    , error : Maybe String
    , nodeOp : NodeOperation
    }


type NodeOperation
    = OpNone
    | OpNodeToAdd NodeToAdd
    | OpNodeMove NodeMove
    | OpNodeCopy NodeCopy
    | OpNodeMessage NodeMessage


type alias NodeView =
    { node : Node
    , feID : Int
    , hasChildren : Bool
    , expDetail : Bool
    , expChildren : Bool
    , mod : Bool
    }


type alias NodeEdit =
    { feID : Int
    , points : List Point
    }


type alias NodeToAdd =
    { typ : Maybe String
    , parent : String
    }


type alias NodeMove =
    { id : String
    , input : String
    , oldParent : String
    , newParent : Maybe String
    }


type alias NodeCopy =
    { id : String
    , input : String
    , newChild : Maybe String
    }


type alias NodeMessage =
    { id : String
    , message : String
    }


defaultModel : Key -> Model
defaultModel key =
    Model
        key
        Nothing
        Time.utc
        (Time.millisToPosix 0)
        Nothing
        { email = "", token = "", isRoot = False }
        Nothing
        OpNone


init : Shared.Model -> Url Params -> ( Model, Cmd Msg )
init shared { key } =
    let
        model =
            defaultModel key
    in
    case shared.auth of
        Just auth ->
            ( { model | auth = auth }
            , Cmd.batch
                [ Task.perform Zone Time.here
                , Task.perform Tick Time.now
                , Node.list { onResponse = ApiRespList, token = auth.token }
                ]
            )

        Nothing ->
            -- this is not ever used as site is redirected at high levels to sign-in
            ( model
            , Utils.Route.navigate shared.key Route.SignIn
            )



-- UPDATE


type Msg
    = Tick Time.Posix
    | Zone Time.Zone
    | EditNodePoint Int Point
    | ToggleExpChildren Int
    | ToggleExpDetail Int
    | DiscardAll
    | DiscardEdits
    | AddNode String
    | MsgNode String
    | DiscardAddNode
    | MoveNode String String
    | CopyNode String
    | DiscardMoveNode
    | UpdateMsg String
    | DiscardMsg
    | MoveNodeDescription String
    | CopyNodeDescription String
    | SelectAddNodeType String
    | ApiDelete String String
    | ApiPostPoints String
    | ApiPostAddNode
    | ApiPostMoveNode
    | ApiPutCopyNode
    | ApiPostMsgNode
    | ApiRespList (Data (List Node))
    | ApiRespDelete (Data Response)
    | ApiRespPostPoint (Data Response)
    | ApiRespPostAddNode (Data Response)
    | ApiRespPostMoveNode (Data Response)
    | ApiRespPutCopyNode (Data Response)
    | ApiRespPostMsgNode (Data Response)
    | Clipboard String


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        EditNodePoint feID point ->
            let
                editPoints =
                    case model.nodeEdit of
                        Just ne ->
                            ne.points

                        Nothing ->
                            []
            in
            ( { model
                | nodeEdit =
                    Just
                        { feID = feID
                        , points = Point.updatePoint editPoints point
                        }
              }
            , Cmd.none
            )

        ApiPostPoints id ->
            case model.nodes of
                Just nodes ->
                    case model.nodeEdit of
                        Just edit ->
                            let
                                points =
                                    Point.clearText edit.points

                                -- optimistically update nodes
                                updatedNodes =
                                    Tree.map
                                        (\n ->
                                            if n.node.id == id then
                                                let
                                                    node =
                                                        n.node
                                                in
                                                { n
                                                    | node =
                                                        { node
                                                            | points = Point.updatePoints node.points points
                                                        }
                                                }

                                            else
                                                n
                                        )
                                        nodes
                            in
                            ( { model | nodeEdit = Nothing, nodes = Just updatedNodes }
                            , Node.postPoints
                                { token = model.auth.token
                                , id = id
                                , points = points
                                , onResponse = ApiRespPostPoint
                                }
                            )

                        Nothing ->
                            ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        DiscardAll ->
            ( { model | nodeOp = OpNone }, Cmd.none )

        DiscardEdits ->
            ( { model | nodeEdit = Nothing }
            , Cmd.none
            )

        ToggleExpChildren feID ->
            let
                nodes =
                    model.nodes |> Maybe.map (toggleExpChildren feID)
            in
            ( { model | nodes = nodes }, Cmd.none )

        ToggleExpDetail feID ->
            let
                nodes =
                    model.nodes |> Maybe.map (toggleExpDetail feID)
            in
            ( { model | nodes = nodes }, Cmd.none )

        AddNode id ->
            ( { model
                | nodeOp = OpNodeToAdd { typ = Nothing, parent = id }
              }
            , Cmd.none
            )

        MsgNode id ->
            ( { model | nodeOp = OpNodeMessage { id = id, message = "" } }, Cmd.none )

        MoveNode id parent ->
            ( { model
                | nodeOp =
                    OpNodeMove
                        { id = id
                        , input = ""
                        , oldParent = parent
                        , newParent = Nothing
                        }
              }
            , Cmd.none
            )

        CopyNode id ->
            ( { model
                | nodeOp =
                    OpNodeCopy
                        { id = id
                        , input = ""
                        , newChild = Nothing
                        }
              }
            , Cmd.none
            )

        DiscardMoveNode ->
            ( { model | nodeOp = OpNone }, Cmd.none )

        UpdateMsg message ->
            case model.nodeOp of
                OpNodeMessage op ->
                    ( { model | nodeOp = OpNodeMessage { op | message = message } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        DiscardMsg ->
            ( { model | nodeOp = OpNone }, Cmd.none )

        MoveNodeDescription desc ->
            case model.nodeOp of
                OpNodeMove move ->
                    let
                        newId =
                            model.nodes
                                |> Maybe.andThen (findNode desc)
                                |> Maybe.map .node
                                |> Maybe.map .id

                        moveNode =
                            { move | input = desc, newParent = newId }
                    in
                    ( { model | nodeOp = OpNodeMove moveNode }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        CopyNodeDescription desc ->
            case model.nodeOp of
                OpNodeCopy copy ->
                    let
                        newId =
                            model.nodes
                                |> Maybe.andThen (findNode desc)
                                |> Maybe.map .node
                                |> Maybe.map .id

                        copyNode =
                            { copy | input = desc, newChild = newId }
                    in
                    ( { model | nodeOp = OpNodeCopy copyNode }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SelectAddNodeType typ ->
            case model.nodeOp of
                OpNodeToAdd add ->
                    ( { model | nodeOp = OpNodeToAdd { add | typ = Just typ } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        DiscardAddNode ->
            ( { model | nodeOp = OpNone }, Cmd.none )

        ApiPostAddNode ->
            -- FIXME optimistically update nodes
            case model.nodeOp of
                OpNodeToAdd addNode ->
                    let
                        nodes =
                            model.nodes |> Maybe.map (expChildren addNode.parent)
                    in
                    case addNode.typ of
                        Just typ ->
                            ( { model | nodeOp = OpNone, nodes = nodes }
                            , Node.insert
                                { token = model.auth.token
                                , onResponse = ApiRespPostAddNode
                                , node =
                                    { id = ""
                                    , typ = typ
                                    , parent = addNode.parent
                                    , points =
                                        [ Point.newText
                                            ""
                                            Point.typeDescription
                                            "New, please edit"
                                        ]
                                    }
                                }
                            )

                        Nothing ->
                            ( { model | nodeOp = OpNone, nodes = nodes }, Cmd.none )

                _ ->
                    ( { model | nodeOp = OpNone }, Cmd.none )

        ApiPostMoveNode ->
            ( model
            , case model.nodeOp of
                OpNodeMove moveNode ->
                    case moveNode.newParent of
                        Just newParent ->
                            Node.move
                                { token = model.auth.token
                                , id = moveNode.id
                                , oldParent = moveNode.oldParent
                                , newParent = newParent
                                , onResponse = ApiRespPostMoveNode
                                }

                        Nothing ->
                            Cmd.none

                _ ->
                    Cmd.none
            )

        ApiPutCopyNode ->
            ( model
            , case model.nodeOp of
                OpNodeCopy copyNode ->
                    case copyNode.newChild of
                        Just newChild ->
                            Node.copy
                                { token = model.auth.token
                                , id = newChild
                                , newParent = copyNode.id
                                , onResponse = ApiRespPutCopyNode
                                }

                        Nothing ->
                            Cmd.none

                _ ->
                    Cmd.none
            )

        ApiPostMsgNode ->
            ( model
            , case model.nodeOp of
                OpNodeMessage msgNode ->
                    Node.message
                        { token = model.auth.token
                        , id = msgNode.id
                        , message = msgNode.message
                        , onResponse = ApiRespPostMsgNode
                        }

                _ ->
                    Cmd.none
            )

        ApiDelete id parent ->
            -- optimistically update nodes
            let
                nodes =
                    -- FIXME Tree.filter (\d -> d.id /= id) model.nodes
                    model.nodes
            in
            ( { model | nodes = nodes }
            , Node.delete
                { token = model.auth.token
                , id = id
                , parent = parent
                , onResponse = ApiRespDelete
                }
            )

        Zone zone ->
            ( { model | zone = zone }, Cmd.none )

        Tick now ->
            ( { model | now = now }
            , updateNodes model
            )

        ApiRespList resp ->
            case resp of
                Data.Success nodes ->
                    let
                        maybeNew =
                            case nodeListToTree nodes of
                                Just tree ->
                                    Just <|
                                        populateHasChildren <|
                                            populateFeID <|
                                                sortNodeTree tree

                                Nothing ->
                                    Nothing

                        treeMerged =
                            case ( model.nodes, maybeNew ) of
                                ( Just current, Just new ) ->
                                    Just <| mergeNodeTree current new

                                ( _, Just new ) ->
                                    Just new

                                ( Just current, _ ) ->
                                    Just current

                                _ ->
                                    Nothing
                    in
                    ( { model | nodes = treeMerged }, Cmd.none )

                Data.Failure err ->
                    let
                        signOut =
                            case err of
                                Http.BadStatus code ->
                                    code == 401

                                _ ->
                                    False
                    in
                    if signOut then
                        ( { model | error = Just "Signed Out" }
                        , Utils.Route.navigate model.key Route.SignIn
                        )

                    else
                        ( popError "Error getting nodes" err model
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        ApiRespDelete resp ->
            case resp of
                Data.Success _ ->
                    ( model
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error deleting device" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , updateNodes model
                    )

        ApiRespPostPoint resp ->
            case resp of
                Data.Success _ ->
                    ( model
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error posting point" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , Cmd.none
                    )

        ApiRespPostAddNode resp ->
            case resp of
                Data.Success _ ->
                    ( model
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error adding node" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , updateNodes model
                    )

        ApiRespPostMoveNode resp ->
            case resp of
                Data.Success _ ->
                    ( { model | nodeOp = OpNone }
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error moving node" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , updateNodes model
                    )

        ApiRespPutCopyNode resp ->
            case resp of
                Data.Success _ ->
                    ( { model | nodeOp = OpNone }
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error copying node" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , updateNodes model
                    )

        ApiRespPostMsgNode resp ->
            case resp of
                Data.Success _ ->
                    ( { model | nodeOp = OpNone }
                    , updateNodes model
                    )

                Data.Failure err ->
                    ( popError "Error messaging node" err model
                    , updateNodes model
                    )

                _ ->
                    ( model
                    , updateNodes model
                    )

        Clipboard contents ->
            ( model, Port.out <| Port.encodeClipboard contents )


mergeNodeTree : Tree NodeView -> Tree NodeView -> Tree NodeView
mergeNodeTree current new =
    let
        z =
            Zipper.fromTree current
    in
    Tree.map
        (\n ->
            case Zipper.findFromRoot (\o -> o.node.id == n.node.id) z of
                Just found ->
                    let
                        l =
                            Zipper.label found
                    in
                    { n
                        | expChildren = l.expChildren
                        , expDetail = l.expDetail
                    }

                Nothing ->
                    n
        )
        new


populateFeID : Tree NodeView -> Tree NodeView
populateFeID tree =
    Tree.indexedMap
        (\i n ->
            { n | feID = i }
        )
        tree


toggleExpChildren : Int -> Tree NodeView -> Tree NodeView
toggleExpChildren feID tree =
    Tree.map
        (\n ->
            if n.feID == feID then
                { n | expChildren = not n.expChildren }

            else
                n
        )
        tree


expChildren : String -> Tree NodeView -> Tree NodeView
expChildren id tree =
    Tree.map
        (\n ->
            if n.node.id == id then
                { n | expChildren = True }

            else
                n
        )
        tree


toggleExpDetail : Int -> Tree NodeView -> Tree NodeView
toggleExpDetail feID tree =
    Tree.map
        (\n ->
            if n.feID == feID then
                { n | expDetail = not n.expDetail }

            else
                n
        )
        tree


findNode : String -> Tree NodeView -> Maybe NodeView
findNode descId tree =
    Zipper.findFromRoot
        (\n -> Node.description n.node == descId || n.node.id == descId)
        (Zipper.fromTree tree)
        |> Maybe.map Zipper.label


nodeListToTree : List Node -> Maybe (Tree NodeView)
nodeListToTree nodes =
    List.Extra.find (\n -> n.parent == "") nodes
        |> Maybe.map (populateChildren nodes)



-- populateChildren takes a list of nodes with a parent field and converts
-- this into a tree


populateChildren : List Node -> Node -> Tree NodeView
populateChildren nodes root =
    Zipper.toTree <|
        populateChildrenHelp
            (Zipper.fromTree <| Tree.singleton (nodeToNodeView root))
            nodes


nodeToNodeView : Node -> NodeView
nodeToNodeView node =
    { node = node
    , feID = 0
    , hasChildren = False
    , expDetail = False
    , expChildren = False
    , mod = False
    }


populateChildrenHelp : Zipper NodeView -> List Node -> Zipper NodeView
populateChildrenHelp z nodes =
    case
        Zipper.forward
            (List.foldr
                (\n zCur ->
                    if (Zipper.label zCur).node.id == n.parent then
                        Zipper.mapTree
                            (\t ->
                                Tree.appendChild
                                    (Tree.singleton
                                        (nodeToNodeView n)
                                    )
                                    t
                            )
                            zCur

                    else
                        zCur
                )
                z
                nodes
            )
    of
        Just zMod ->
            populateChildrenHelp zMod nodes

        Nothing ->
            z


populateHasChildren : Tree NodeView -> Tree NodeView
populateHasChildren tree =
    let
        children =
            Tree.children tree

        hasChildren =
            List.length children > 0

        label =
            Tree.label tree

        node =
            { label | hasChildren = hasChildren }
    in
    tree
        |> Tree.replaceLabel node
        |> Tree.replaceChildren
            (List.map
                (\c -> populateHasChildren c)
                children
            )



-- sortNodeTree recursively sorts the children of the nodes


sortNodeTree : Tree NodeView -> Tree NodeView
sortNodeTree nodes =
    let
        children =
            Tree.children nodes

        childrenSorted =
            List.sortWith
                (\a b ->
                    let
                        aNode =
                            Tree.label a

                        bNode =
                            Tree.label b

                        aDescription =
                            Point.getText aNode.node.points Point.typeDescription

                        bDescription =
                            Point.getText bNode.node.points Point.typeDescription
                    in
                    compare bDescription aDescription
                )
                children
    in
    Tree.tree (Tree.label nodes) (List.map sortNodeTree childrenSorted)


popError : String -> Http.Error -> Model -> Model
popError desc err model =
    { model | error = Just (desc ++ ": " ++ Data.errorToString err) }


updateNodes : Model -> Cmd Msg
updateNodes model =
    Node.list { onResponse = ApiRespList, token = model.auth.token }


save : Model -> Shared.Model -> Shared.Model
save model shared =
    { shared
        | error =
            case model.error of
                Nothing ->
                    shared.error

                Just _ ->
                    model.error
        , lastError =
            case model.error of
                Nothing ->
                    shared.lastError

                Just _ ->
                    shared.now
    }


load : Shared.Model -> Model -> ( Model, Cmd Msg )
load shared model =
    ( { model | key = shared.key, error = Nothing }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Time.every 5000 Tick
        ]



-- VIEW


view : Model -> Document Msg
view model =
    { title = "SIOT Nodes"
    , body =
        [ column
            [ width fill, spacing 32 ]
            [ el Style.h2 <| text "Nodes"
            , viewNodes model
            ]
        ]
    }


viewNodes : Model -> Element Msg
viewNodes model =
    column
        [ width fill
        , spacing 24
        ]
    <|
        case model.nodes of
            Just tree ->
                let
                    treeWithEdits =
                        mergeNodeEdit tree model.nodeEdit
                in
                viewNode model Nothing (Tree.label treeWithEdits) 0
                    :: viewNodesHelp 1 model treeWithEdits

            Nothing ->
                [ text "No nodes to display" ]


viewNodesHelp :
    Int
    -> Model
    -> Tree NodeView
    -> List (Element Msg)
viewNodesHelp depth model tree =
    let
        node =
            Tree.label tree

        children =
            if node.expChildren then
                Tree.children tree

            else
                []
    in
    List.foldr
        (\child ret ->
            let
                childNode =
                    Tree.label child
            in
            if shouldDisplay childNode.node.typ then
                ret
                    ++ viewNode model (Just node) childNode depth
                    :: viewNodesHelp (depth + 1) model child

            else
                ret
        )
        []
        children


shouldDisplay : String -> Bool
shouldDisplay typ =
    case typ of
        "user" ->
            True

        "group" ->
            True

        "modbus" ->
            True

        "modbusIo" ->
            True

        "rule" ->
            True

        "condition" ->
            True

        "action" ->
            True

        "device" ->
            True

        "msgService" ->
            True

        "variable" ->
            True

        _ ->
            False


viewNode : Model -> Maybe NodeView -> NodeView -> Int -> Element Msg
viewNode model parent node depth =
    let
        nodeView =
            case node.node.typ of
                "user" ->
                    NodeUser.view

                "group" ->
                    NodeGroup.view

                "modbus" ->
                    NodeModbus.view

                "modbusIo" ->
                    NodeModbusIO.view

                "rule" ->
                    NodeRule.view

                "condition" ->
                    NodeCondition.view

                "action" ->
                    NodeAction.view

                "device" ->
                    NodeDevice.view

                "msgService" ->
                    NodeMessageService.view

                "variable" ->
                    NodeVariable.view

                _ ->
                    viewUnknown
    in
    el
        [ width fill
        , paddingEach { top = 0, right = 0, bottom = 0, left = depth * 35 }
        , Form.onEnterEsc (ApiPostPoints node.node.id) DiscardAll
        ]
    <|
        row [ spacing 6 ]
            [ el [ alignTop ] <|
                if not node.hasChildren then
                    Icon.dot

                else if node.expChildren then
                    Button.arrowDown (ToggleExpChildren node.feID)

                else
                    Button.arrowRight (ToggleExpChildren node.feID)
            , el [ alignTop ] <|
                if node.expDetail then
                    Button.close (ToggleExpDetail node.feID)

                else
                    Button.edit (ToggleExpDetail node.feID)
            , column
                [ spacing 6, width fill ]
                [ nodeView
                    { isRoot = model.auth.isRoot
                    , now = model.now
                    , zone = model.zone
                    , modified = node.mod
                    , parent = Maybe.map .node parent
                    , node = node.node
                    , expDetail = node.expDetail
                    , onEditNodePoint = EditNodePoint node.feID
                    }
                , viewIf node.mod <|
                    Form.buttonRow
                        [ Form.button
                            { label = "save"
                            , color = colors.blue
                            , onPress = ApiPostPoints node.node.id
                            }
                        , Form.button
                            { label = "discard"
                            , color = colors.gray
                            , onPress = DiscardEdits
                            }
                        ]
                , if node.expDetail then
                    case model.nodeOp of
                        OpNone ->
                            viewNodeOperations node.node.id node.node.parent

                        OpNodeToAdd add ->
                            if add.parent == node.node.id then
                                viewAddNode node.node add

                            else
                                viewNodeOperations node.node.id node.node.parent

                        OpNodeMove move ->
                            if move.id == node.node.id then
                                viewMoveNode move

                            else
                                viewNodeOperations node.node.id node.node.parent

                        OpNodeCopy copy ->
                            if copy.id == node.node.id then
                                viewCopyNode copy

                            else
                                viewNodeOperations node.node.id node.node.parent

                        OpNodeMessage msg ->
                            if msg.id == node.node.id then
                                viewMsgNode msg

                            else
                                viewNodeOperations node.node.id node.node.parent

                  else
                    Element.none
                ]
            ]


viewUnknown :
    { isRoot : Bool
    , now : Time.Posix
    , zone : Time.Zone
    , modified : Bool
    , expDetail : Bool
    , parent : Maybe Node
    , node : Node
    , onEditNodePoint : Point -> msg
    }
    -> Element msg
viewUnknown o =
    Element.text <| "unknown node type: " ++ o.node.typ


viewNodeOperations : String -> String -> Element Msg
viewNodeOperations id parent =
    row [ spacing 6 ]
        [ Button.plusCircle (AddNode id)
        , if parent /= "" then
            Button.move (MoveNode id parent)

          else
            Element.none
        , Button.message (MsgNode id)
        , Button.x (ApiDelete id parent)
        , Button.copy (Clipboard id)
        ]


viewMoveNode : NodeMove -> Element Msg
viewMoveNode move =
    el [ paddingEach { top = 10, right = 0, left = 0, bottom = 0 } ] <|
        column [ spacing 10 ]
            [ Input.text []
                { text = move.input
                , placeholder = Just <| Input.placeholder [] <| text "description/id"
                , label = Input.labelAbove [] <| text "New parent node: "
                , onChange = MoveNodeDescription
                }
            , Form.buttonRow
                [ case move.newParent of
                    Just _ ->
                        Form.button
                            { label = "move"
                            , color = Style.colors.blue
                            , onPress = ApiPostMoveNode
                            }

                    Nothing ->
                        Element.none
                , Form.button
                    { label = "cancel"
                    , color = Style.colors.gray
                    , onPress = DiscardMoveNode
                    }
                ]
            ]


viewCopyNode : NodeCopy -> Element Msg
viewCopyNode copy =
    el [ paddingEach { top = 10, right = 0, left = 0, bottom = 0 } ] <|
        column [ spacing 10 ]
            [ Input.text []
                { text = copy.input
                , placeholder = Just <| Input.placeholder [] <| text "description/id"
                , label = Input.labelAbove [] <| text "Add existing node: "
                , onChange = CopyNodeDescription
                }
            , Form.buttonRow
                [ case copy.newChild of
                    Just _ ->
                        Form.button
                            { label = "add"
                            , color = Style.colors.blue
                            , onPress = ApiPutCopyNode
                            }

                    Nothing ->
                        Element.none
                , Form.button
                    { label = "cancel"
                    , color = Style.colors.gray
                    , onPress = DiscardMoveNode
                    }
                ]
            ]


viewAddNode : Node -> NodeToAdd -> Element Msg
viewAddNode parent add =
    column [ spacing 10 ]
        [ Input.radio [ spacing 6 ]
            { onChange = SelectAddNodeType
            , selected = add.typ
            , label = Input.labelAbove [] (el [ padding 12 ] <| text "Select node type to add: ")
            , options =
                []
                    ++ (if parent.typ == Node.typeDevice then
                            [ Input.option Node.typeUser (text "User")
                            , Input.option Node.typeGroup (text "Group")
                            , Input.option Node.typeRule (text "Rule")
                            , Input.option Node.typeModbus (text "Modbus")
                            , Input.option Node.typeMsgService (text "Messaging Service")
                            , Input.option Node.typeVariable (text "Variable")
                            ]

                        else
                            []
                       )
                    ++ (if parent.typ == Node.typeGroup then
                            [ Input.option Node.typeUser (text "User")
                            , Input.option Node.typeGroup (text "Group")
                            , Input.option Node.typeRule (text "Rule")
                            , Input.option Node.typeMsgService (text "Messaging Service")
                            , Input.option Node.typeVariable (text "Variable")
                            , Input.option "existing" (text "Existing node")
                            ]

                        else
                            []
                       )
                    ++ (if parent.typ == Node.typeModbus then
                            [ Input.option Node.typeModbusIO (text "Modbus IO") ]

                        else
                            []
                       )
                    ++ (if parent.typ == Node.typeRule then
                            [ Input.option Node.typeCondition (text "Condition")
                            , Input.option Node.typeAction (text "Action")
                            ]

                        else
                            []
                       )
            }
        , Form.buttonRow
            [ case add.typ of
                Just _ ->
                    Form.button
                        { label = "add"
                        , color = Style.colors.blue
                        , onPress =
                            if add.typ == Just "existing" then
                                CopyNode parent.id

                            else
                                ApiPostAddNode
                        }

                Nothing ->
                    Element.none
            , Form.button
                { label = "cancel"
                , color = Style.colors.gray
                , onPress = DiscardAddNode
                }
            ]
        ]


viewMsgNode : NodeMessage -> Element Msg
viewMsgNode msg =
    el [ paddingEach { top = 10, right = 0, left = 0, bottom = 0 } ] <|
        column
            [ width fill, spacing 32 ]
            [ Input.multiline [ width fill ]
                { onChange = UpdateMsg
                , text = msg.message
                , placeholder = Nothing
                , label = Input.labelAbove [] <| text "Send message to users:"
                , spellcheck = True
                }
            , Form.buttonRow
                [ Form.button
                    { label = "send now"
                    , color = Style.colors.blue
                    , onPress = ApiPostMsgNode
                    }
                , Form.button
                    { label = "cancel"
                    , color = Style.colors.gray
                    , onPress = DiscardMsg
                    }
                ]
            , paragraph [] [ text "Considering adding your name at the end of the message. A personal touch is always nice! :-)" ]
            ]


mergeNodeEdit : Tree NodeView -> Maybe NodeEdit -> Tree NodeView
mergeNodeEdit nodes nodeEdit =
    case nodeEdit of
        Just edit ->
            Tree.map
                (\n ->
                    if edit.feID == n.feID then
                        let
                            node =
                                n.node
                        in
                        { n
                            | mod = True
                            , node =
                                { node
                                    | points =
                                        Point.updatePoints node.points edit.points
                                }
                        }

                    else
                        { n | mod = False }
                )
                nodes

        Nothing ->
            Tree.map (\n -> { n | mod = False }) nodes
