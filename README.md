# CoAP Publish-Subscribe interface to RabbitMQ

Plug-in for the [RabbitMQ broker](http://www.rabbitmq.com)
implementing the Publish-Subscribe Broker for the
[Constrained Application Protocol (CoAP)](http://coap.technology).

This is an experimental implementation of the
[draft-koster-core-coap-pubsub-02](https://www.ietf.org/id/draft-koster-core-coap-pubsub-02.txt).

## Interactions

### Quick Introduction

You can perform all standard operations:
 - Obtain the `/ps` subtree by `GET /.well-known/core?rt=core.ps`
 - Create topic by `POST /ps "<topic1>"`
 - Publish to a topic by `PUT /ps/topic1 "1033.3"`
 - Subscribe to a topic by `GET /ps/topic1 Observe:0 Token:XX`
 - Receive publications as `2.05 Content Token:XX`
 - Unsubscribe from a topic by `GET /ps/topic1 Observe:1 Token:XX`
 - Get the most recent published value by `GET /ps/topic1`
 - Remove a topic by `DELETE /ps/topic1`

You may use the command-line tool from [libcoap](https://libcoap.net/). For example,
to subscribe for 10 seconds to `/ps/topic1` you should type

    $ ./coap-client -m get coap://127.0.0.1/ps/topic1 -s 10 -T "XX"

### RabbitMQ Behaviour

Each topic is implemented as an RabbitMQ exchange. Subscription to a topic is
implemented using a temporary RabbitMQ queue bound to that exchange.

Retrieval of the most recent published value requires a caching exchange, i.e.
either [x-lvc](https://github.com/rabbitmq/rabbitmq-lvc-plugin)
or [x-recent-history](https://github.com/videlalvaro/rabbitmq-recent-history-exchange).

## Installation

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
