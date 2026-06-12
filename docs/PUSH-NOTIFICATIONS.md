# Push Notifications — connector reference (archived)

> **Status: parked / reference only.** This captures information from the A2A connector
> engineer (diagram + a repo MUnit example + written notes) so we can implement push
> notifications later. Nothing here is wired into the wrapper yet. The diagram the engineer
> sent is for protocol **v1.0.0**; the notes below translate it to our **v0.3.0** terms.
>
> Source: connector product/engineering contact, provided ahead of full examples expected
> later. Verify component/operation names against the connector version we actually use
> (A2A connector **1.1.1**) before building — the example XML predates it.

> **Where we left off (resume here):** parked to focus on an
> agent-network / broker integration demo. Blocked on the connector engineer (via the product contact)
> sending fuller examples. When picking back up:
> 1. Resolve the **§6 open questions** first — above all, confirm `push-notification-config-listener`,
>    `on-config-accepted`, `proxy-config`, and **`send-push-notification`** exist (with these
>    shapes) in connector **1.1.1**, and the `send-push-notification` signature (Task/Message
>    arg? how it resolves which task?).
> 2. Then build per **§5**: set the card `capabilities.pushNotifications: true`, add the
>    config-listener flow (URL validation), and call `send-push-notification` at the trigger
>    points — terminal states **and `input-required`** (the HITL-over-push differentiator).
> 3. Effort is **low-to-medium** — the connector owns storage/auth/proxy/delivery; our net-new
>    is one listener flow + a few `send-push-notification` calls + the card flag.
> The UI already has a disabled push stub (`PushPanel.vue`) and the card advertises
> `pushNotifications:false`.

---

## 1. The model in one paragraph

Push notifications let a **disconnected** A2A client get told about task progress via a
**webhook callback** instead of holding a streaming connection. The client supplies a
`pushNotificationConfig` (a callback `url`, an auth `token`, optional proxy/timeout). The
**connector** validates it (via a listener flow we provide), stores it, and — when our task
flow calls a **server operation** — delivers the notification (a Task or Message object) to
every callback registered for that task. **We do not POST the webhook ourselves**; the
connector owns storage, auth, proxy, and delivery. Our job is: (a) advertise the capability,
(b) validate incoming configs, (c) call "send push notification" at the right moments.

---

## 2. Request flow (transcribed from the engineer's diagram)

`Connector Listeners` box, by entry operation:

- **SendStreamingMessage**, **SendMessage(non-blocking)** → **Streaming and Async Listener
  (custom headers)** → **Initial Task** → (`Mandatory Task`) → **Task Listener**.
- **SendMessage(blocking)** → **Task Listener** directly.
- **Task Listener** → `update status isFinal:false` → `update artifact` → `update status
  isFinal:true`. Annotation on this leg: *"No more task edits allowed in this part.
  `@EmitsResponse` and `@OnSuccess` work as is."*
- **SendMessage(push notifications)**, **CreatePushNotificationConfig** → **Push Notification
  Config Listener** → **Validate Config** → *get operation from Request Attributes* →
  decision **"is SM or CPNC?"**
  - **SM** (SendMessage) → **Initial Task** → (`Mandatory Task + Effective PN Config`) →
    back into **Task Listener** (task now proceeds, carrying the effective PN config).
  - **CPNC** (CreatePushNotificationConfig) → *return Effective PN Config to user* (a
    standalone config-set call; no task is run).
- **GetTask**, **SubscribeToTask** → **Authorization Listener**.

Legend: `SM = SendMessage`, `CPNC = CreatePushNotificationConfig`.

Key takeaways from the diagram:
- A `message/send` that **includes** a `pushNotificationConfig` is routed to the **Push
  Notification Config Listener FIRST**, not straight to the task listener. After validation
  it produces the Initial Task (state `submitted`) and *then* the task runs in the Task
  Listener with the "effective PN config" attached.
- `CreatePushNotificationConfig` is the standalone CRUD path — it validates + stores a config
  and returns the effective config without running a task.
- `GetTask` / `SubscribeToTask` (resubscribe) go through the **Authorization Listener** — the
  same listener we already use for `tasks/cancel`.

---

## 3. Components & operations involved

**A2A Server (our wrapper side):**
- `<a2a:push-notification-config-listener config-ref="...">` — new listener. Its flow is
  where we **validate** an incoming `pushNotificationConfig`. Child config:
  - `<a2a:on-config-accepted>` → `<a2a:proxy-config>` → `<http:proxy host port/>` — declares
    delivery-time settings (proxy shown; the notes also mention request timeout + auth).
- `<a2a:send-push-notification>` — **server operation called from inside the task-listener
  flow** to actually deliver a notification (Task or Message object) to all configs for the
  task. *(Exact element/operation name to confirm in 1.1.1.)*
- Agent card must set `capabilities.pushNotifications: true`.

**A2A Client side (for our own client flows / testing):**
- `set`, `get`, `delete` operations = CRUD on the push-notification configs for a task
  (A2A `tasks/pushNotificationConfig/{set,get,delete}`).

---

## 4. Worked example (MUnit test from the connector repo)

Demonstrates: send a message *with* a `pushNotificationConfig`, run the task, and assert the
callback URL received the completed task. Uses a local **proxy** between connector and
callback to prove proxy support.

Notable pieces:
- **Client send** carries the config inline:
  ```xml
  <a2a:send-message config-ref="A2A_Client_config">
    <a2a:message><![CDATA[{
      "message": { "role": "user", "messageId": "message-id-1", "kind": "message",
                   "parts": [ { "kind": "text", "text": "What's the capital of France?" } ] },
      "configuration": {
        "pushNotificationConfig": {
          "url": "http://localhost:${notification.http.port}/callback/success",
          "token": "test-auth-token-123"
        }
      }
    }]]></a2a:message>
  </a2a:send-message>
  ```
- **Server config listener** accepts the config and declares a proxy for delivery:
  ```xml
  <a2a:push-notification-config-listener config-ref="A2A_Server_config_PN_supported">
    <a2a:on-config-accepted>
      <a2a:proxy-config>
        <http:proxy host="localhost" port="${proxy.server.port}"/>
      </a2a:proxy-config>
    </a2a:on-config-accepted>
  </a2a:push-notification-config-listener>
  ```
- **Server task listener** returns the completed task (here a static "Paris" answer). In a
  real agent this is where our Claude turn runs — and where we'd invoke
  `send-push-notification`.
- **Callback flow** is a plain `http:listener` on `/callback/success` that stores the POSTed
  body. The test then asserts:
  - the synchronous `send-message` response has `status.state == 'submitted'`,
  - after a 10s sleep, the stored callback payload has
    `result.status.state == 'completed'`, a non-null `result.id`, and the message text
    `containsString('Paris')`.

So the **delivered webhook body is the A2A Task object** (`result` = the task), and delivery
is asynchronous (the sync response is just `submitted`).

The full XML is preserved verbatim at the end of this file (§8).

---

## 5. How this maps to OUR wrapper (analysis)

Today the wrapper has `a2a-server.xml` (blocking task-listener), `a2a-stream.xml`
(task-stream-listener), `a2a-authorize.xml` (authorization-listener for `tasks/cancel`),
plus the Claude client + confirmation routing. To add push, we'd need roughly:

1. **Card flag** — set `capabilities.pushNotifications: true` in `agent-card.json` (currently
   advertised `false`). Trivial.
2. **Config listener flow (new)** — add `<a2a:push-notification-config-listener>` + a flow
   that validates the incoming `pushNotificationConfig` (at minimum: URL present + parseable;
   optionally allow-list hosts). Throw to get the `INVALID_PARAMS` rejection; return normally
   to accept. Declare proxy/timeout/auth under `on-config-accepted` as needed.
3. **Emit notifications from the task flow** — call `<a2a:send-push-notification>` at the
   moments a disconnected client cares about. Our task processing lives in the
   blocking/stream listeners (and the shared Claude-turn logic), so we'd add the call where we
   already emit terminal status. Candidate trigger points:
   - **terminal states**: `completed`, `failed`, `canceled` — the obvious ones.
   - **`input-required` (HITL pause)** — arguably the *most* valuable: a disconnected caller
     can be pinged the instant the task needs a tool approval, then act via
     `message/send` continuation. This is a strong differentiator for our HITL design.
4. **Client CRUD (optional)** — if we want the standalone `tasks/pushNotificationConfig/set|
   get|delete` path (CPNC in the diagram), that's handled by the same config listener; the
   inline-on-send path and the standalone path share validation/storage.

**Effort:** likely **low-to-medium**. The heavy lifting (storage, auth header, proxy,
delivery, retry?) is the connector's. Our net-new is one listener flow + a handful of
`send-push-notification` calls + a card flag. The real *design* work is choosing trigger
points and the validation policy, not plumbing.

**Fits cleanly** with the existing architecture: the config listener is independent of the
task listeners, and `send-push-notification` slots in next to our existing
`update-task-status` / `update-task-artifact` calls.

---

## 6. Open questions for the connector team

1. **Version parity:** are `push-notification-config-listener`, `on-config-accepted`,
   `proxy-config`, and `send-push-notification` all present in connector **1.1.1** with these
   names/shapes? The example predates our version.
2. **`send-push-notification` signature:** does it take the Task/Message object explicitly, or
   build from current task state? How does it resolve *which* task (from flow attributes, or an
   explicit `taskId`)? Can it be called multiple times per task (e.g. on every status change)?
3. **Streaming + push together:** can a client request streaming *and* a push config? The
   diagram routes push via the Task Listener, not the streaming listener — is push limited to
   blocking/non-blocking sends, or does it compose with `task-stream-listener`?
4. **Auth:** how is the config `token` applied on delivery (header name? bearer?) and what
   other auth schemes does `on-config-accepted` support?
5. **Delivery semantics:** retries/backoff on callback failure? timeout config location?
   delivery on **non-terminal** updates, or only terminal? (The notes say we choose when to
   call it, implying any state.)
6. **Storage:** does the config listener need a specific object-store-ref, or does the
   connector manage its own store (like task history)?
7. **`INVALID_PARAMS`:** confirm that throwing in the config-listener flow yields the
   `INVALID_PARAMS` JSON-RPC error to the caller (engineer was "if I remember correctly").

---

## 7. Verbatim engineer notes

> Here is an image to help you understand the flow with push notifications. This diagram is
> compliant with v1.0.0 of the protocol, but let me translate for you in v0.3.0 protocol terms.
>
> **For A2A Server**
> 1. In order for push notification to work in your agent, your agent card must have
>    `pushNotifications` flag set to true and your mule xml should have the component
>    `push-notification-config-listener`.
> 2. Any `message/send` requests which has `pushNotificationConfig` within the payload, is
>    first heard at this `push-notification-config-listener`.
> 3. `push-notification-config-listener` has details that you can configure when you want to
>    send the notification like proxy, request timeout, authentication etc.
> 4. The flow backed by the `push-notification-config-listener` is for you to do validations on
>    the `pushNotificationConfig` whether URL entered is correct or whatever you want to do with it.
> 5. If the validations fail or throw an error, a corresponding `INVALID_PARAMS` jsonrpc error
>    is thrown. (if I remember correctly)
> 6. If the validations are a success, then once the callback is triggered for
>    `push-notification-config-listener`, the connector will wrap the details like URL, proxy,
>    auth, timeout and keep it in the object store, and return to the client, a task with its
>    state as "submitted".
> 7. Then the actual task-processing occurs in the mule flow backed by `task-listener`.
> 8. Within this `task-listener`, you can use the `send-push-notification` server operation, to
>    send the notification (which is a task or message object) to all the notification
>    configurations you have supplied for that task.
>
> **For A2A Client**
> You can use the set, get, and delete operations to do CRUD operations on the push
> notification configurations for that task.

---

## 8. Verbatim example XML (connector repo MUnit test)

```xml
<?xml version="1.0" encoding="UTF-8"?>

<mule xmlns:ee="http://www.mulesoft.org/schema/mule/ee/core"
      xmlns:a2a="http://www.mulesoft.org/schema/mule/a2a"
      xmlns:http="http://www.mulesoft.org/schema/mule/http"
      xmlns="http://www.mulesoft.org/schema/mule/core"
      xmlns:doc="http://www.mulesoft.org/schema/mule/documentation"
      xmlns:munit="http://www.mulesoft.org/schema/mule/munit"
      xmlns:munit-tools="http://www.mulesoft.org/schema/mule/munit-tools"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="
        http://www.mulesoft.org/schema/mule/core http://www.mulesoft.org/schema/mule/core/current/mule.xsd
        http://www.mulesoft.org/schema/mule/http http://www.mulesoft.org/schema/mule/http/current/mule-http.xsd
        http://www.mulesoft.org/schema/mule/a2a http://www.mulesoft.org/schema/mule/a2a/current/mule-a2a.xsd
        http://www.mulesoft.org/schema/mule/ee/core http://www.mulesoft.org/schema/mule/ee/core/current/mule-ee.xsd
        http://www.mulesoft.org/schema/mule/munit http://www.mulesoft.org/schema/mule/munit/current/mule-munit.xsd
        http://www.mulesoft.org/schema/mule/munit-tools http://www.mulesoft.org/schema/mule/munit-tools/current/mule-munit-tools.xsd">

    <munit:config name="Push Notification Test 2 - Test Push Notification with callback via http proxy" doc:name="MUnit configuration"/>
    <import file="test-config.xml"/>
    <import file="client-test-config.xml"/>

    <!-- HTTP Listener for callback testing -->
    <http:listener-config name="Callback_HTTP_Listener_config_1" doc:name="Callback HTTP Listener config">
        <http:listener-connection host="0.0.0.0" port="${notification.http.port}"/>
    </http:listener-config>

    <!-- HTTP Listener for callback testing -->
    <http:listener-config name="Proxy_Server_config_1" doc:name="Proxy Server config">
        <http:listener-connection host="0.0.0.0" port="${proxy.server.port}"/>
    </http:listener-config>

    <!-- Flow: Valid push notification config with token -->
    <flow name="sendMessageWithPushNotificationWithProxy">
        <a2a:send-message doc:name="Send Message with Push Notification" config-ref="A2A_Client_config">
            <a2a:message ><![CDATA[{
                "message": {
                  "role": "user",
                  "messageId": "message-id-1",
                  "kind": "message",
                  "parts": [
                    {
                      "kind": "text",
                      "text": "What's the capital of France?"
                    }
                  ]
                },
                "configuration": {
                  "pushNotificationConfig": {
                    "url": "http://localhost:${notification.http.port}/callback/success",
                    "token": "test-auth-token-123"
                  }
                }
            }]]></a2a:message>
        </a2a:send-message>
        <set-variable value="#[payload]" doc:name="Set Variable" variableName="submittedResponse"/>
        <set-variable value="#[payload.result.id]" doc:name="Set Variable" variableName="submittedResponseTaskId"/>
    </flow>

    <!-- Callback endpoint for successful tests -->
    <flow name="callbackSuccessFlow">
        <http:listener config-ref="Callback_HTTP_Listener_config_1" path="/callback/success" allowedMethods="POST"/>
        <munit-tools:store key="notificationPayload">
            <munit-tools:value>#[payload]</munit-tools:value>
        </munit-tools:store>
    </flow>

    <http:request-config name="HTTP_Request_direct">
        <http:request-connection host="localhost" port="${notification.http.port}"/>
    </http:request-config>

    <!-- Flow: Proxy server flow to redirect request -->
    <flow name="localProxyFlow_1">
        <http:listener config-ref="Proxy_Server_config_1" path="*" allowedMethods="POST,GET"/>
        <logger level="DEBUG" message="Inside proxy logger with path #[attributes]"/>
        <http:request config-ref="HTTP_Request_direct" method="#[attributes.method]" path="#[attributes.requestPath]">
            <http:headers><![CDATA[#[attributes.headers]]]></http:headers>
        </http:request>
    </flow>

    <!-- Server task listener flow -->
    <flow name="serverTaskListenerPushFlow_2">
        <a2a:task-listener doc:name="Task Listener with Push" config-ref="A2A_Server_config_PN_supported"/>
        <ee:transform>
            <ee:message>
                <ee:set-payload><![CDATA[#[%dw 2.0
output application/json
---
{
    "id": attributes.taskId,
    "contextId": attributes.contextId,
    "status": {
        "state": "completed",
        "message": {
            "messageId": "message-id-1",
            "kind": "message",
            "role": "agent",
            "parts": [
                {
                    "kind": "text",
                    "text": "The capital of France is Paris. It's a beautiful city known for its rich history, culture, and iconic landmarks like the Eiffel Tower."
                }
            ]
        },
        "timestamp": "2025-01-17T21:23:51.929957Z"
    },
    "artifacts": [],
    "kind": "task"
}
]]]></ee:set-payload>
            </ee:message>
        </ee:transform>
    </flow>

    <!-- Push notification config listener flow -->
    <flow name="pushNotificationConfigListenerFlow_2">
        <a2a:push-notification-config-listener doc:name="Push Notification Config Listener" config-ref="A2A_Server_config_PN_supported">
            <a2a:on-config-accepted >
                <a2a:proxy-config >
                    <http:proxy host="localhost" port="${proxy.server.port}"/>
                </a2a:proxy-config>
            </a2a:on-config-accepted>
        </a2a:push-notification-config-listener>
        <logger level="DEBUG" doc:name="Push Notification Flow Logger" doc:id="6a08129f-3fef-4cda-9cfb-e6b953f24324" message="payload is #[payload]"/>
    </flow>

    <!-- Test: Valid push notification config with token -->
    <munit:test name="testValidPushNotificationWithToken" description="Test push notification with valid config and token">
        <munit:enable-flow-sources>
            <munit:enable-flow-source value="serverTaskListenerPushFlow_2"/>
            <munit:enable-flow-source value="callbackSuccessFlow"/>
            <munit:enable-flow-source value="localProxyFlow_1"/>
            <munit:enable-flow-source value="pushNotificationConfigListenerFlow_2"/>
            <munit:enable-flow-source value="getAgentCardForPushNotificationFlow"/>
        </munit:enable-flow-sources>
        <munit:behavior>
            <flow-ref name="sendMessageWithPushNotificationWithProxy"/>
        </munit:behavior>
        <munit:validation>

            <munit-tools:assert-that expression="#[vars.submittedResponse]" is="#[MunitTools::notNullValue()]"/>

            <!-- Result Object Validation -->
            <munit-tools:assert-that expression="#[vars.submittedResponse.id]" is="#[MunitTools::notNullValue()]"/>
            <munit-tools:assert-that expression="#[vars.submittedResponse.contextId]" is="#[MunitTools::notNullValue()]"/>
            <munit-tools:assert-that expression="#[vars.submittedResponse.status]" is="#[MunitTools::notNullValue()]"/>

            <!-- Status Object Validation -->
            <munit-tools:assert-that expression="#[vars.submittedResponse.status.state]" is="#[MunitTools::equalTo('submitted')]"/>
            <munit-tools:assert-that expression="#[vars.submittedResponse.status.timestamp]" is="#[MunitTools::notNullValue()]"/>

            <!-- Specific Task ID Validation (if known) -->
            <munit-tools:assert-that expression="#[vars.submittedResponse.id]" is="#[MunitTools::notNullValue()]"/>

            <!-- Validation for contextId - should not be null and should be a string -->
            <munit-tools:assert-that expression="#[vars.submittedResponse.contextId is String]" is="#[MunitTools::equalTo(true)]"/>

            <!-- Timestamp Format Validation - should not be null and should be a string -->
            <munit-tools:assert-that expression="#[vars.submittedResponse.status.timestamp is String]" is="#[MunitTools::equalTo(true)]"/>
            <munit-tools:sleep time="10000" timeUnit="MILLISECONDS"/>

            <munit-tools:retrieve key="notificationPayload" target="notification"/>
            <munit-tools:assert-that expression="#[vars.notification.result.status.state]" is="#[MunitTools::equalTo('completed')]"/>
            <munit-tools:assert-that expression="#[vars.notification.result.id]" is="#[MunitTools::notNullValue()]"/>
            <munit-tools:assert-that expression="#[vars.notification.result.status.message.parts[0].text]" is="#[MunitTools::containsString('Paris')]"/>
        </munit:validation>
    </munit:test>

</mule>
```
