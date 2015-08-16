# CoAP Publish-Subscribe interface to RabbitMQ

Plug-in for the [RabbitMQ broker](http://www.rabbitmq.com)
implementing the Publish-Subscribe Broker for the
[Constrained Application Protocol (CoAP)](http://coap.technology).

This is an experimental implementation of the
[draft-koster-core-coap-pubsub-02](https://www.ietf.org/id/draft-koster-core-coap-pubsub-02.txt).
Not for operational use.

## Interactions

### Quick Introduction

RabbitMQ will listen for UDP packets on port 5683.
You can use the command-line tool from [libcoap](https://libcoap.net/), or any
other CoAP client and perform all standard operations:

 - Obtain the `/ps` subtree by `GET /.well-known/core?rt=core.ps`
   <pre>
   $ ./coap-client coap://127.0.0.1/.well-known/core?rt=core.ps
   </pre>
 - Create topic by `POST /ps "<topic1>"`
   <pre>
   $ ./coap-client -m post coap://127.0.0.1/ps -e "&lt;topic1>"
   </pre>
 - Publish to a topic by `PUT /ps/topic1 "1033.3"`
   <pre>
   $ ./coap-client -m put coap://127.0.0.1/ps/topic1 -e "1033.3"
   </pre>
 - Get the most recent published value by `GET /ps/topic1`<br/>
   Note, this operation requires a caching exchange, e.g. either
   [x-lvc](https://github.com/rabbitmq/rabbitmq-lvc-plugin) or
   [x-recent-history](https://github.com/videlalvaro/rabbitmq-recent-history-exchange).
   <pre>
   $ ./coap-client coap://127.0.0.1/ps/topic1
   </pre>
 - Subscribe to a topic by `GET /ps/topic1 Observe:0 Token:XX`
 - Receive publications as `2.05 Content Token:XX`
   <pre>
   $ ./coap-client coap://127.0.0.1/ps/topic1 -s 10 -T "XX"
   </pre>
 - Unsubscribe from a topic by `GET /ps/topic1 Observe:1 Token:XX`
 - Remove a topic by `DELETE /ps/topic1`<br/>
   Note, this will also terminate all CoAP observers of this topic.
   <pre>
   $ ./coap-client -m delete coap://127.0.0.1/ps/topic1
   </pre>

### RabbitMQ Behaviour

Each CoAP topic is implemented as an RabbitMQ exchange. Subscription to a topic is
implemented using a temporary RabbitMQ queue bound to that exchange.

Names of the temporary queues are composed from a prefix `coap/`, IP:port of the
subscriber and the token characters. For example, a subscription from 127.0.0.1:40212
using the token `HH` will be served by the queue `coap/127.0.0.1:40212/4848`. Deleting
this queue will forcibly terminate the observer.

Retrieval of the most recent published value requires a caching exchange, i.e.
either [x-lvc](https://github.com/rabbitmq/rabbitmq-lvc-plugin)
or [x-recent-history](https://github.com/videlalvaro/rabbitmq-recent-history-exchange).
Subscription to other exchange types is possible, but the GET operation will
succeed only once a new message published.

The implementation intentionally differs from the draft-02 in the following aspects:
 - The POST and DELETE operations are idempotent. Creating a topic that already exist
   causes 2.01 "Created" instead of 4.03 "Forbidden". Similarly, deleting a topic
   that does not exist causes 2.02 "Deleted".


## Installation

### RabbitMQ Configuration
Add the plug-in configuration section. See
[RabbitMQ Configuration](https://www.rabbitmq.com/configure.html) for more details.

<table>
  <tbody>
    <tr>
      <th>Key</th>
      <th>Documentation</th>
    </tr>
    <tr>
      <td><pre>resources</pre></td>
      <td>
        Virtual Hosts accessible via CoAP and corresponding pub/sub Function Set paths.
        The path is defined as a list of strings; each string defines one segment
        of the absolute path to the resource.
        <br/>
        Default: <pre>[{<<"/">>, ["ps"]}]</pre>
      </td>
    </tr>
    <tr>
      <td><pre>exchange_type</pre></td>
      <td>
        Exchange type used by CoAP generated topics. It is recommended to use
        a caching exchange.
        <br/>
        Default: <pre><<"direct">></pre>
      </td>
    </tr>
  </tbody>
</table>

For example:
```erlang
{rabbitmq_coap_pubsub, [
    {resources, [
        {<<"/">>, ["ps"]}
    ]},
    {exchange_type, <<"x-lvc">>}
]}
```

### Installation from source

First, download and build
[RabbitMQ gen_coap Integration](https://github.com/gotthardp/rabbitmq-gen-coap).
The `rabbitmq-gen-coap` provides a generic Erlang CoAP server and client, which may be
used by multiple plug-ins.

Then, build and activate the RabbitMQ plug-in `rabbitmq-coap-pubsub`. See the
[Plugin Development Guide](http://www.rabbitmq.com/plugin-development.html)
for more details.

    $ git clone https://github.com/rabbitmq/rabbitmq-public-umbrella.git
    $ cd rabbitmq-public-umbrella
    $ make co
    $ ./foreachrepo git checkout <tag>
    $ git clone https://github.com/gotthardp/rabbitmq-coap-pubsub.git
    $ cd rabbitmq-coap-pubsub
    $ make

## Copyright and Licensing

Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>

This package is subject to the Mozilla Public License Version 2.0 (the "License");
you may not use this file except in compliance with the License. You may obtain a
copy of the License at http://mozilla.org/MPL/2.0/.

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for the
specific language governing rights and limitations under the License.
