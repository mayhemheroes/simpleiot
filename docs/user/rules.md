# Rules

**Contents**

<!-- toc -->

The Simple IoT application has the ability to run rules. That are composed of
one or more conditions and actions. All conditions must be true for the rule to
be active.

Node point changes cause rules of any parent node in the tree to be run. This
allows general rules to be written higher in the tree that are common for all
device nodes (for instance device offline).

In the below configuration, a change in the SBC propagates up the node tree,
thus both the `D5 on rule` or the `Device offline rule` are eligible to be run.

![rules](images/rules.png)

## Node linking

Both conditions and actions can be linked to a node ID. If you copy a node, its
ID is stored in a virtual clipboard and displayed at the top of the screen. You
can then paste this node ID into the Node ID field in a condition or action.

![rule-linking](images/rule-copy-paste-node-id.png)

## Conditions

Each condition may optionally specify a minimum active duration before the
condition is considered met. This allows timing to be encoded in the rules.

### Node state

A point value condition looks at the point value of a node to determine if a
condition is met. Qualifiers that filter points the condition is interested in
may be set including:

- node ID (if left blank, any node that is a descendent of the rule parent)
- point type ("value" is probably the most common type)
- point Key (used to index into point arrays and objects)

If the provided qualification is met, then the condition may check the point
value/text fields for a number of conditions including:

- number: `>`, `<`, `=`, `!=`
- text: `=`, `!=`, `contains`
- boolean: `on`, `off`

### Schedule

TODO:

## Actions

Every action has an optional repeat interval. This allows rate limiting of
actions like notifications.

### Notifications

Notifications are the simplest rule action and are sent out when:

- all conditions are met
- time since last notification is greater than the notify action repeat
  interval.

Every time a notification is sent out by a rule, a point is created/updated in
the rule with the following fields:

- id: node of point that triggered the rule
- type: "lastNotificationSent"
- time: time the notification was sent

Before sending a notification we scan the points of the rule looking for when
the last notification was sent to decide if its time to send it.

### Set node point

Rules can also set points in other nodes. For simplicity, the node ID must be
currently specified along with point parameters and a number/bool/text value.

Typically a rule action is only used to set one value. In the case of on/off
actions, one rule is used to turn a value on, and another rule is used to turn
the same value off. This allows for hysteresis and more complex logic than in
one rule handled both the on and off states. This also allows the rules logic to
be stateful.
