package store

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/simpleiot/simpleiot/client"
	"github.com/simpleiot/simpleiot/data"
	"github.com/simpleiot/simpleiot/internal/pb"
	"github.com/simpleiot/simpleiot/msg"
	"google.golang.org/protobuf/proto"
)

var reportMetricsPeriod = time.Minute

// NewTokener provides a new authentication token.
type NewTokener interface {
	NewToken(userID string) (string, error)
}

// Store implements the SIOT NATS api
type Store struct {
	server           string
	nc               *nats.Conn
	subNodePoints    *nats.Subscription
	subEdgePoints    *nats.Subscription
	subNode          *nats.Subscription
	subChildren      *nats.Subscription
	subNotifications *nats.Subscription
	subMessages      *nats.Subscription
	subAuth          *nats.Subscription
	db               *Db
	authToken        string
	lock             sync.Mutex
	nodeUpdateLock   sync.Mutex
	updates          map[string]time.Time
	key              NewTokener

	// cycle metrics track how long it takes to handle a point
	metricCycleNodePoint     *client.Metric
	metricCycleNodeEdgePoint *client.Metric
	metricCycleNode          *client.Metric
	metricCycleNodeChildren  *client.Metric

	// Pending counts how many points are being buffered by the NATS client
	metricPendingNodePoint     *client.Metric
	metricPendingNodeEdgePoint *client.Metric

	// influx db stuff
	influxDbs     map[string]*Influx
	chStop        chan struct{}
	chStopMetrics chan struct{}

	// sync stuff
	startedLock sync.Mutex
	started     bool
	wait        []chan struct{}
}

// Params are used to configure a store
type Params struct {
	Type      Type
	DataDir   string
	AuthToken string
	Server    string
	Key       NewTokener
	Nc        *nats.Conn
}

// NewStore creates a new NATS client for handling SIOT requests
func NewStore(p Params) (*Store, error) {
	db, err := NewDb(p.Type, p.DataDir)
	if err != nil {
		return nil, fmt.Errorf("Error opening db: %v", err)
	}

	log.Println("store connecting to nats server: ", p.Server)
	return &Store{
		db:            db,
		authToken:     p.AuthToken,
		updates:       make(map[string]time.Time),
		server:        p.Server,
		influxDbs:     make(map[string]*Influx),
		key:           p.Key,
		nc:            p.Nc,
		chStop:        make(chan struct{}),
		chStopMetrics: make(chan struct{}),
	}, nil
}

// Start connects to NATS server and set up handlers for things we are interested in
func (st *Store) Start() error {
	var err error
	st.subNodePoints, err = st.nc.Subscribe("node.*.points", st.handleNodePoints)
	if err != nil {
		return fmt.Errorf("Subscribe node points error: %w", err)
	}

	st.subEdgePoints, err = st.nc.Subscribe("node.*.*.points", st.handleEdgePoints)
	if err != nil {
		return fmt.Errorf("Subscribe edge points error: %w", err)
	}

	if st.subNode, err = st.nc.Subscribe("node.*", st.handleNode); err != nil {
		return fmt.Errorf("Subscribe node error: %w", err)
	}

	if st.subChildren, err = st.nc.Subscribe("node.*.children", st.handleNodeChildren); err != nil {
		return fmt.Errorf("Subscribe node error: %w", err)
	}

	if st.subNotifications, err = st.nc.Subscribe("node.*.not", st.handleNotification); err != nil {
		return fmt.Errorf("Subscribe notification error: %w", err)
	}

	if st.subMessages, err = st.nc.Subscribe("node.*.msg", st.handleMessage); err != nil {
		return fmt.Errorf("Subscribe message error: %w", err)
	}

	if st.subAuth, err = st.nc.Subscribe("auth.user", st.handleAuthUser); err != nil {
		return fmt.Errorf("Subscribe auth error: %w", err)
	}

	// we don't have node ID yet, but need to init here so we can start
	// collecting data
	st.metricCycleNodePoint = client.NewMetric(st.nc, "",
		data.PointTypeMetricNatsCycleNodePoint, reportMetricsPeriod)
	st.metricCycleNodeEdgePoint = client.NewMetric(st.nc, "",
		data.PointTypeMetricNatsCycleNodeEdgePoint, reportMetricsPeriod)
	st.metricCycleNode = client.NewMetric(st.nc, "",
		data.PointTypeMetricNatsCycleNode, reportMetricsPeriod)
	st.metricCycleNodeChildren = client.NewMetric(st.nc, "",
		data.PointTypeMetricNatsCycleNodeChildren, reportMetricsPeriod)

	st.startedLock.Lock()
	st.started = true
	for _, c := range st.wait {
		close(c)
	}
	st.startedLock.Unlock()

	t := time.NewTimer(time.Millisecond)

	for {
		select {
		case <-st.chStop:
			log.Println("Store stopped")
			return errors.New("Store stopped")
		case <-t.C:
			childNodes, err := st.db.nodeDescendents(st.db.rootNodeID(), "", false, false)
			if err != nil {
				log.Println("Error getting child nodes to run schedule: ", err)
			} else {
				for _, c := range childNodes {
					err := st.runSchedule(c)
					if err != nil {
						log.Println("Error running schedule: ", err)
					}
				}
			}
			t.Reset(time.Second * 5)
		}
	}
}

// Stop the store
func (st *Store) Stop(err error) {
	close(st.chStop)
}

// WaitStart waits for store to start
func (st *Store) WaitStart(ctx context.Context) error {
	st.startedLock.Lock()
	if st.started {
		st.startedLock.Unlock()
		return nil
	}

	wait := make(chan struct{})
	st.wait = append(st.wait, wait)
	st.startedLock.Unlock()

	select {
	case <-ctx.Done():
		return errors.New("Store wait timeout or canceled")
	case <-wait:
		return nil
	}
}

// StartMetrics for various handling operations. Metrics are sent to the node ID given
// FIXME, this can probably move to the node package for device nodes
func (st *Store) StartMetrics(nodeID string) error {
	st.metricCycleNodePoint.SetNodeID(nodeID)
	st.metricCycleNodeEdgePoint.SetNodeID(nodeID)
	st.metricCycleNode.SetNodeID(nodeID)
	st.metricCycleNodeChildren.SetNodeID(nodeID)

	st.metricPendingNodePoint = client.NewMetric(st.nc, nodeID,
		data.PointTypeMetricNatsPendingNodePoint, reportMetricsPeriod)
	st.metricPendingNodeEdgePoint = client.NewMetric(st.nc, nodeID,
		data.PointTypeMetricNatsPendingNodeEdgePoint, reportMetricsPeriod)

	t := time.NewTimer(time.Millisecond)

	for {
		select {
		case <-st.chStopMetrics:
			return errors.New("Store stopping metrics")

		case <-t.C:
			pendingNodePoints, _, err := st.subNodePoints.Pending()
			if err != nil {
				log.Println("Error getting pendingNodePoints: ", err)
			}

			err = st.metricPendingNodePoint.AddSample(float64(pendingNodePoints))
			if err != nil {
				log.Println("Error handling metric: ", err)
			}

			pendingEdgePoints, _, err := st.subEdgePoints.Pending()
			if err != nil {
				log.Println("Error getting pendingEdgePoints: ", err)
			}

			err = st.metricPendingNodeEdgePoint.AddSample(float64(pendingEdgePoints))
			if err != nil {
				log.Println("Error handling metric: ", err)
			}
			t.Reset(time.Second * 10)
		}
	}
}

// StopMetrics ...
func (st *Store) StopMetrics(_ error) {
	close(st.chStopMetrics)
}

func (st *Store) runSchedule(node data.NodeEdge) error {
	switch node.Type {
	case data.NodeTypeRule:
		p := data.Point{Time: time.Now(), Type: data.PointTypeTrigger}
		err := st.processRuleNode(node, "", []data.Point{p})
		if err != nil {
			return err
		}

	case data.NodeTypeGroup:
		childNodes, err := st.db.nodeDescendents(node.ID, "", false, false)
		if err != nil {
			return err
		}
		for _, c := range childNodes {
			err := st.runSchedule(c)
			if err != nil {
				return err
			}
		}
	}

	return nil
}

func (st *Store) setSwUpdateState(id string, state data.SwUpdateState) error {
	p := state.Points()

	return client.SendNodePoints(st.nc, id, p, false)
}

// StartUpdate starts an update
func (st *Store) StartUpdate(id, url string) error {
	st.lock.Lock()
	defer st.lock.Unlock()

	if _, ok := st.updates[id]; ok {
		return fmt.Errorf("Update already in process for dev: %v", id)
	}

	st.updates[id] = time.Now()

	err := st.setSwUpdateState(id, data.SwUpdateState{
		Running: true,
	})

	if err != nil {
		delete(st.updates, id)
		return err
	}

	go func() {
		err := NatsSendFileFromHTTP(st.nc, id, url, func(bytesTx int) {
			err := st.setSwUpdateState(id, data.SwUpdateState{
				Running:     true,
				PercentDone: bytesTx,
			})

			if err != nil {
				log.Println("Error setting update status in DB: ", err)
			}
		})

		state := data.SwUpdateState{
			Running: false,
		}

		if err != nil {
			state.Error = "Error updating software"
			state.PercentDone = 0
		} else {
			state.PercentDone = 100
		}

		st.lock.Lock()
		delete(st.updates, id)
		st.lock.Unlock()

		err = st.setSwUpdateState(id, state)
		if err != nil {
			log.Println("Error setting sw update state: ", err)
		}
	}()

	return nil
}

func (st *Store) handleNodePoints(msg *nats.Msg) {
	start := time.Now()
	defer func() {
		t := time.Since(start).Milliseconds()
		st.metricCycleNodePoint.AddSample(float64(t))
	}()
	st.nodeUpdateLock.Lock()
	defer st.nodeUpdateLock.Unlock()

	nodeID, points, err := client.DecodeNodePointsMsg(msg)

	if err != nil {
		fmt.Printf("Error decoding nats message: %v: %v", msg.Subject, err)
		st.reply(msg.Reply, errors.New("error decoding node points subject"))
		return
	}

	// write points to database
	err = st.db.nodePoints(nodeID, points)

	if err != nil {
		// TODO track error stats
		log.Printf("Error writing nodeID (%v) to Db: %v", nodeID, err)
		log.Println("msg subject: ", msg.Subject)
		st.reply(msg.Reply, err)
		return
	}

	node, err := st.db.node(nodeID)
	if err != nil {
		log.Println("handleNodePoints, error getting node for id: ", nodeID)
	}

	desc := node.Desc()

	// process point in upstream nodes
	err = st.processPointsUpstream(nodeID, nodeID, desc, points)
	if err != nil {
		// TODO track error stats
		log.Println("Error processing point in upstream nodes: ", err)
	}

	st.reply(msg.Reply, nil)
}

func (st *Store) handleEdgePoints(msg *nats.Msg) {
	start := time.Now()
	defer func() {
		t := time.Since(start).Milliseconds()
		st.metricCycleNodeEdgePoint.AddSample(float64(t))
	}()

	st.nodeUpdateLock.Lock()
	defer st.nodeUpdateLock.Unlock()

	nodeID, parentID, points, err := client.DecodeEdgePointsMsg(msg)

	if err != nil {
		fmt.Printf("Error decoding nats message: %v: %v", msg.Subject, err)
		st.reply(msg.Reply, errors.New("error decoding edge points subject"))
		return
	}

	// write points to database
	err = st.db.edgePoints(nodeID, parentID, points)

	if err != nil {
		// TODO track error stats
		log.Printf("Error writing edge points (%v:%v) to Db: %v", nodeID, parentID, err)
		log.Println("msg subject: ", msg.Subject)
		st.reply(msg.Reply, err)
	}

	st.reply(msg.Reply, nil)
}

func (st *Store) handleNode(msg *nats.Msg) {
	start := time.Now()
	defer func() {
		t := time.Since(start).Milliseconds()
		st.metricCycleNode.AddSample(float64(t))
	}()

	resp := &pb.NodesRequest{}
	var parent string
	var nodeID string
	var nodes data.Nodes
	var err error
	nodesRet := data.Nodes{}

	chunks := strings.Split(msg.Subject, ".")
	if len(chunks) < 2 {
		resp.Error = fmt.Sprintf("Error in message subject: %v", msg.Subject)
		goto handleNodeDone
	}

	parent = string(msg.Data)

	nodeID = chunks[1]

	nodes, err = st.db.nodeEdge(nodeID, parent)

	// remove deleted nodes
	if parent == "all" {
		for _, n := range nodes {
			ts, _ := n.IsTombstone()
			if !ts {
				nodesRet = append(nodesRet, n)
			}
		}
	} else {
		nodesRet = nodes
	}

	if err != nil {
		if err != data.ErrDocumentNotFound {
			resp.Error = fmt.Sprintf("NATS handler: Error getting node %v from db: %v\n", nodeID, err)
		} else {
			resp.Error = data.ErrDocumentNotFound.Error()
		}
	}

handleNodeDone:
	resp.Nodes, err = nodesRet.ToPbNodes()
	if err != nil {
		resp.Error = fmt.Sprintf("Error pb encoding node: %v\n", err)
	}

	data, err := proto.Marshal(resp)

	err = st.nc.Publish(msg.Reply, data)
	if err != nil {
		log.Println("NATS: Error publishing response to node request: ", err)
	}
}

// TODO, maybe someday we should return error node instead of no data
func (st *Store) handleAuthUser(msg *nats.Msg) {
	var points data.Points
	var err error
	resp := &pb.NodesRequest{}

	returnNothing := func() {
		err = st.nc.Publish(msg.Reply, nil)
		if err != nil {
			log.Println("NATS: Error publishing response to auth.user")
		}
	}

	if len(msg.Data) <= 0 {
		log.Println("No data in auth.user")
		returnNothing()
		return
	}

	points, err = data.PbDecodePoints(msg.Data)
	if err != nil {
		log.Println("Error decoding auth.user params: ", err)
		returnNothing()
		return
	}

	emailP, ok := points.Find(data.PointTypeEmail, "")
	if !ok {
		log.Println("Error, auth.user no email point")
		returnNothing()
		return
	}

	passP, ok := points.Find(data.PointTypePass, "")
	if !ok {
		log.Println("Error, auth.user no password point")
		returnNothing()
		return
	}

	nodes, err := st.db.userCheck(emailP.Text, passP.Text)

	if err != nil || len(nodes) <= 0 {
		log.Println("Error, invalid user")
		returnNothing()
		return
	}

	user, err := data.NodeToUser(nodes[0].ToNode())

	token, err := st.key.NewToken(user.ID)
	if err != nil {
		log.Println("Error creating token")
		returnNothing()
		return
	}

	nodes = append(nodes, data.NodeEdge{
		Type: data.NodeTypeJWT,
		Points: data.Points{
			{
				Type: data.PointTypeToken,
				Text: token,
			},
		},
	})

	resp.Nodes, err = nodes.ToPbNodes()
	if err != nil {
		resp.Error = fmt.Sprintf("Error pb encoding node: %v\n", err)
	}

	data, err := proto.Marshal(resp)

	err = st.nc.Publish(msg.Reply, data)
	if err != nil {
		log.Println("NATS: Error publishing response to node request: ", err)
	}
}

func (st *Store) handleNodeChildren(msg *nats.Msg) {
	start := time.Now()
	defer func() {
		t := time.Since(start).Milliseconds()
		st.metricCycleNodeChildren.AddSample(float64(t))
	}()

	resp := &pb.NodesRequest{}
	params := pb.NatsRequest{}
	var err error
	var nodes data.Nodes
	var nodeID string

	chunks := strings.Split(msg.Subject, ".")
	if len(chunks) < 3 {
		resp.Error = fmt.Sprintf("Error in message subject: %v", msg.Subject)
		goto handleNodeChildrenDone
	}

	// decode request params
	if len(msg.Data) > 0 {
		err := proto.Unmarshal(msg.Data, &params)
		if err != nil {
			resp.Error = fmt.Sprintf("Error decoding Node children request params: %v", err)
			goto handleNodeChildrenDone
		}
	}

	nodeID = chunks[1]

	nodes, err = st.db.nodeDescendents(nodeID, params.Type, false, params.IncludeDel)

	if err != nil {
		resp.Error = fmt.Sprintf("NATS: Error getting node %v from db: %v\n", nodeID, err)
		goto handleNodeChildrenDone
	}

handleNodeChildrenDone:
	resp.Nodes, err = nodes.ToPbNodes()
	if err != nil {
		resp.Error = fmt.Sprintf("Error pb encoding nodes: %v", err)
	}

	data, err := proto.Marshal(resp)
	if err != nil {
		resp.Error = fmt.Sprintf("Error encoding data: %v", err)
	}

	err = st.nc.Publish(msg.Reply, data)

	if err != nil {
		log.Println("NATS: Error publishing response to node children request: ", err)
	}
}

func (st *Store) handleNotification(msg *nats.Msg) {
	chunks := strings.Split(msg.Subject, ".")
	if len(chunks) < 2 {
		log.Println("Error in message subject: ", msg.Subject)
		return
	}

	nodeID := chunks[1]

	not, err := data.PbDecodeNotification(msg.Data)

	if err != nil {
		log.Println("Error decoding Pb notification: ", err)
		return
	}

	userNodes := []data.NodeEdge{}

	var findUsers func(id string)

	findUsers = func(id string) {
		nodes, err := st.db.nodeDescendents(id, data.NodeTypeUser, false, false)
		if err != nil {
			log.Println("Error find user nodes: ", err)
			return
		}

		for _, n := range nodes {
			userNodes = append(userNodes, n)
		}

		// now process upstream nodes
		upIDs := st.db.edgeUp(id, false)
		if err != nil {
			log.Println("Error getting upstream nodes: ", err)
			return
		}

		for _, id := range upIDs {
			findUsers(id.Up)
		}
	}

	node, err := st.db.node(nodeID)

	if err != nil {
		log.Println("Error getting node: ", nodeID)
		return
	}

	if node.Type == data.NodeTypeUser {
		// if we notify a user node, we only want to message this node, and not walk up the tree
		nodeEdge := node.ToNodeEdge(data.Edge{Up: not.Parent})
		userNodes = append(userNodes, nodeEdge)
	} else {
		findUsers(nodeID)
	}

	for _, userNode := range userNodes {
		user, err := data.NodeToUser(userNode.ToNode())

		if err != nil {
			log.Println("Error converting node to user: ", err)
			continue
		}

		if user.Email != "" || user.Phone != "" {
			msg := data.Message{
				ID:             uuid.New().String(),
				UserID:         user.ID,
				ParentID:       userNode.Parent,
				NotificationID: nodeID,
				Email:          user.Email,
				Phone:          user.Phone,
				Subject:        not.Subject,
				Message:        not.Message,
			}

			data, err := msg.ToPb()

			if err != nil {
				log.Println("Error serializing msg to protobuf: ", err)
				continue
			}

			err = st.nc.Publish("node."+user.ID+".msg", data)

			if err != nil {
				log.Println("Error publishing message: ", err)
				continue
			}
		}
	}
}

func (st *Store) handleMessage(natsMsg *nats.Msg) {
	chunks := strings.Split(natsMsg.Subject, ".")
	if len(chunks) < 2 {
		log.Println("Error in message subject: ", natsMsg.Subject)
		return
	}

	nodeID := chunks[1]

	message, err := data.PbDecodeMessage(natsMsg.Data)

	if err != nil {
		log.Println("Error decoding Pb message: ", err)
		return
	}

	svcNodes := []data.NodeEdge{}

	var findSvcNodes func(string)

	level := 0

	findSvcNodes = func(id string) {
		nodes, err := st.db.nodeDescendents(id, data.NodeTypeMsgService, false, false)
		if err != nil {
			log.Println("Error getting svc descendents: ", err)
			return
		}

		svcNodes = append(svcNodes, nodes...)

		// now process upstream nodes
		// if we are at the first level, only process the msg user parent, instead
		// of all user parents. This eliminates duplicate messages when a user is a
		// member of multiple groups which may have different notification services.

		var upIDs []*data.Edge

		if level == 0 {
			upIDs = []*data.Edge{&data.Edge{Up: message.ParentID}}
		} else {
			upIDs = st.db.edgeUp(id, false)
			if err != nil {
				log.Println("Error getting upstream nodes: ", err)
				return
			}
		}

		level++

		for _, id := range upIDs {
			findSvcNodes(id.Up)
		}
	}

	findSvcNodes(nodeID)

	svcNodes = data.RemoveDuplicateNodesID(svcNodes)

	for _, svcNode := range svcNodes {
		svc, err := data.NodeToMsgService(svcNode.ToNode())
		if err != nil {
			log.Println("Error converting node to msg service: ", err)
			continue
		}

		if svc.Service == data.PointValueTwilio &&
			message.Phone != "" {
			twilio := msg.NewTwilio(svc.SID, svc.AuthToken, svc.From)

			err := twilio.SendSMS(message.Phone, message.Message)

			if err != nil {
				log.Printf("Error sending SMS to: %v: %v\n",
					message.Phone, err)
			}
		}
	}
}

// used for messages that want an ACK
func (st *Store) reply(subject string, err error) {
	if subject == "" {
		// node is not expecting a reply
		return
	}

	reply := ""

	if err != nil {
		reply = err.Error()
	}

	st.nc.Publish(subject, []byte(reply))
}

func (st *Store) processRuleNode(ruleNode data.NodeEdge, sourceNodeID string, points []data.Point) error {
	conditionNodes, err := st.db.nodeDescendents(ruleNode.ID, data.NodeTypeCondition,
		false, false)
	if err != nil {
		return err
	}

	actionNodes, err := st.db.nodeDescendents(ruleNode.ID, data.NodeTypeAction,
		false, false)
	if err != nil {
		return err
	}

	actionInactiveNodes, err := st.db.nodeDescendents(ruleNode.ID,
		data.NodeTypeActionInactive,
		false, false)
	if err != nil {
		return err
	}

	rule, err := data.NodeToRule(ruleNode, conditionNodes, actionNodes, actionInactiveNodes)

	if err != nil {
		return err
	}

	active, changed, err := ruleProcessPoints(st.nc, rule, sourceNodeID, points)

	if err != nil {
		log.Println("Error processing rule point: ", err)
	}

	if active && changed {
		err := st.ruleRunActions(st.nc, rule, rule.Actions, sourceNodeID)
		if err != nil {
			log.Println("Error running rule actions: ", err)
		}

		err = st.ruleRunInactiveActions(st.nc, rule.ActionsInactive)
		if err != nil {
			log.Println("Error running rule inactive actions: ", err)
		}
	}

	if !active && changed {
		err := st.ruleRunActions(st.nc, rule, rule.ActionsInactive, sourceNodeID)
		if err != nil {
			log.Println("Error running rule actions: ", err)
		}

		err = st.ruleRunInactiveActions(st.nc, rule.Actions)
		if err != nil {
			log.Println("Error running rule inactive actions: ", err)
		}
	}

	return nil
}

func (st *Store) processPointsUpstream(currentNodeID, nodeID, nodeDesc string, points data.Points) error {
	// at this point, the point update has already been written to the DB

	// FIXME we could optimize this a bit if the points are not valid for rule nodes ...
	// get children and process any rules
	ruleNodes, err := st.db.nodeDescendents(currentNodeID, data.NodeTypeRule, false, false)
	if err != nil {
		return err
	}

	for _, ruleNode := range ruleNodes {
		err := st.processRuleNode(ruleNode, nodeID, points)
		if err != nil {
			return err
		}
	}

	// get database nodes
	dbNodes, err := st.db.nodeDescendents(currentNodeID, data.NodeTypeDb, false, false)

	for _, dbNode := range dbNodes {
		// check if we need to configure influxdb connection
		idb, ok := st.influxDbs[dbNode.ID]

		if !ok {
			influxConfig, err := NodeToInfluxConfig(dbNode)
			if err != nil {
				log.Println("Error with influxdb node: ", err)
				continue
			}
			idb = NewInflux(influxConfig)
			st.influxDbs[dbNode.ID] = idb
			time.Sleep(time.Second)
		} else {
			if time.Since(idb.lastChecked) > time.Second*20 {
				influxConfig, err := NodeToInfluxConfig(dbNode)
				if err != nil {
					log.Println("Error with influxdb node: ", err)
					continue
				}
				idb.CheckConfig(influxConfig)
			}
		}

		err = idb.WritePoints(nodeID, nodeDesc, points)

		if err != nil {
			log.Println("Error writing point to influx: ", err)
		}
	}

	edges := st.db.edgeUp(currentNodeID, true)

	if currentNodeID == nodeID {
		// check if device node that it has not been orphaned
		node, err := st.db.node(nodeID)
		if err != nil {
			log.Println("Error getting node: ", err)
		}

		if node.Type == data.NodeTypeDevice {
			hasUpstream := false
			for _, e := range edges {
				if !e.IsTombstone() {
					hasUpstream = true
				}
			}

			if !hasUpstream {
				fmt.Println("STORE: orphaned node: ", node)
				if len(edges) < 1 {
					// create upstream edge
					err := client.SendEdgePoint(st.nc, nodeID, "none", data.Point{
						Type:  data.PointTypeTombstone,
						Value: 0,
					}, false)
					if err != nil {
						log.Println("Error sending edge point: ", err)
					}
				} else {
					// undelete existing edge
					e := edges[0]
					err := client.SendEdgePoint(st.nc, e.Down, e.Up, data.Point{
						Type:  data.PointTypeTombstone,
						Value: 0,
					}, false)
					if err != nil {
						log.Println("Error sending edge point: ", err)
					}
				}
			}
		}
	}

	for _, edge := range edges {
		err = st.processPointsUpstream(edge.Up, nodeID, nodeDesc, points)
		if err != nil {
			log.Println("Rules -- error processing upstream node: ", err)
		}
	}

	return nil
}