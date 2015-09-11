# CoAP Publish-Subscribe interface to RabbitMQ
Plug-in for the [RabbitMQ broker](http://www.rabbitmq.com)
implementing the Publish-Subscribe Broker for the
[Constrained Application Protocol (CoAP)](http://coap.technology),
which is designed for the
[Constrained RESTful Environments](https://datatracker.ietf.org/wg/core/charter).

The REST architecture style promotes client-server operations on
cacheable *resources*. This plug-in implements a REST API for the the
[Last Value Cache](https://github.com/rabbitmq/rabbitmq-lvc-plugin);
a CoAP *resource* represents an information in the cache and
(AMQP) messages represent updates of the cached information.

This is an experimental implementation of the
[draft-koster-core-coap-pubsub-02](https://www.ietf.org/id/draft-koster-core-coap-pubsub-02.txt).
Not for operational use.

## Interactions

### Quick Introduction

RabbitMQ will listen for UDP packets on port 5683.
You can use the command-line tool from [libcoap](https://libcoap.net/), or any
other CoAP client and perform all standard operations:

 - Discover the `/ps` function and available resources by `GET /.well-known/core`.
   Returns a link to the pub/sub function and a list of resources that can be accessed
   by the user "anonymous", or an empty list of the user "anonymous" does not exist.
   <pre>
   $ ./coap-client coap://127.0.0.1/.well-known/core?rt=core.ps
   &lt;/ps>;rt="core.ps",&lt;/ps/%2F/topic1>;ct=0;sz=15600
   </pre>
 - Create a topic by `POST /ps/vhost "<topic1>"`.
   The broker will create an x-lvc exchange named "topic1" in a given vhost.
   <pre>
   $ ./coap-client -m post coap://127.0.0.1/ps/%2f -e "&lt;topic1>"
   </pre>
 - Publish to a topic by `PUT /ps/vhost/topic1 "1033.3"` or `PUT /ps/vhost/topic1/key "1033.3"`.
   The broker will publish a message to the exchange "topic1" in a given vhost,
   optionally using the routing key "key".
   <pre>
   $ ./coap-client -m put coap://127.0.0.1/ps/%2f/topic1 -e "1033.3"
   </pre>
 - Get the most recent published value by `GET /ps/vhost/topic1` or `GET /ps/vhost/topic1/key`
   <pre>
   $ ./coap-client coap://127.0.0.1/ps/%2f/topic1
   1033.3
   </pre>
 - Subscribe to a topic by `GET /ps/vhost/topic1 Observe:0` or `GET /ps/vhost/topic1/key Observe:0`
 - Receive publications as `2.05 Content`
   <pre>
   $ ./coap-client coap://127.0.0.1/ps/%2f/topic1 -s 10
   </pre>
 - Remove a topic by `DELETE /ps/vhost/topic1`<br/>
   The broker will delete the exchange "topic1" in a given vhost and terminate
   all CoAP observers of this topic.
   <pre>
   $ ./coap-client -m delete coap://127.0.0.1/ps/%2f/topic1
   </pre>

All CoAP clients are authenticated as a user "anonymous". By setting RabbitMQ
permissions for this user you can restrict access rights of the CoAP clients.
The authenticated DTLS access is not supported (for now).

### RabbitMQ Behaviour

Each CoAP topic is implemented as an RabbitMQ exchange. Subscription to a topic is
implemented using a temporary RabbitMQ queue bound to that exchange. The observers
are persistent, i.e. survive RabbitMQ restart.

Names of the temporary queues are composed from a prefix `coap/`, IP:port of the
subscriber and the token characters. For example, a subscription from 127.0.0.1:40212
using the token `HH` will be served by the queue `coap/127.0.0.1:40212/4848`. Deleting
this queue will forcibly terminate the observer.

The implementation intentionally differs from the draft-02 in the following aspects:
 - The POST and DELETE operations are idempotent. Creating a topic that already exist
   causes 2.01 "Created" instead of 4.03 "Forbidden". Similarly, deleting a topic
   that does not exist causes 2.02 "Deleted".
 - Topic values are listed under `.well-known/core` as standard resources.


## Installation

This plug-in requires the
[Last value caching exchange](https://github.com/rabbitmq/rabbitmq-lvc-plugin).
Please make sure that both `rabbitmq_lvc` and `rabbitmq_coap_pubsub` are installed.

### RabbitMQ Configuration
To change the default settings you may add the `rabbitmq_coap_pubsub` section
to your [RabbitMQ Configuration](https://www.rabbitmq.com/configure.html).

<table>
  <tbody>
    <tr>
      <th>Key</th>
      <th>Documentation</th>
    </tr>
    <tr>
      <td><pre>prefix</pre></td>
      <td>
        Path to the pub/sub Function. The path is defined as a list of strings;
        each string defines one segment of the absolute path to the resource.
        <br/>
        Default: <pre>[<<"ps">>]</pre>
      </td>
    </tr>
  </tbody>
</table>

For example:
```erlang
{rabbitmq_coap_pubsub, [
    {prefix, ["ps"]}
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

Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>. All Rights Reserved.

This package is subject to the Mozilla Public License Version 1.1 (the "License");
you may not use this file except in compliance with the License. You may obtain a
copy of the License at http://www.mozilla.org/MPL/.

Software distributed under the License is distributed on an "AS IS" basis,
WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for the
specific language governing rights and limitations under the License.
