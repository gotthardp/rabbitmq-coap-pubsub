%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_amqp_client).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gen_coap/include/coap.hrl").

-export([init_connection/2, create_topic/3, delete_topic/3, publish/5]).
-export([set_message_from_amqp/3]).

init_connection({PeerIP, PeerPortNo, _Token}, VHost) ->
    amqp_connection:start(
        #amqp_params_direct{username = <<"anonymous">>,
                            virtual_host = VHost,
                            adapter_info = #amqp_adapter_info{protocol  = {'CoAP', "1"},
                                                              name      = list_to_binary(lists:concat(["udp/", inet:ntoa(PeerIP), ":", PeerPortNo])),
                                                              peer_host = PeerIP,
                                                              peer_port = PeerPortNo}}).

create_topic(Observer, VHost, Exchange) ->
    case init_connection(Observer, VHost) of
        {ok, Connection} -> create_topic0(Connection, VHost, Exchange);
        {error, access_refused} -> {error, forbidden, "Access Refused"}
    end.

create_topic0(Connection, _VHost, Exchange) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(ExChannel,
            #'exchange.declare'{exchange = Exchange,
                                durable = true,
                                type = <<"x-lvc">>}) of
        #'exchange.declare_ok'{} ->
            amqp_channel:close(ExChannel),
            ok;
        % when the exchange already exists with different parameters
        {'EXIT', {{shutdown, {server_initiated_close, 406, Error}}, _From}} ->
            {error, forbidden, Error}
    end.

delete_topic(Observer, VHost, Exchange) ->
    case init_connection(Observer, VHost) of
        {ok, Connection} -> delete_topic0(Connection, VHost, Exchange);
        {error, access_refused} -> {error, forbidden, "Access Refused"}
    end.

delete_topic0(Connection, VHost, Exchange) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(ExChannel,
            #'exchange.delete'{exchange = Exchange}) of
        #'exchange.delete_ok'{} ->
            % remove all CoAP consumers bound to this exchange
            lists:foreach(
                fun (#binding{destination=#resource{
                                                    kind=queue,
                                                    name= <<"coap/", _Tail/binary>>=QName}}) ->
                        delete_queue(QName, Connection);
                    (_Other) ->
                        ok
                end,
                rabbit_binding:list_for_source(rabbit_misc:r(VHost, exchange, Exchange))),
            amqp_channel:close(ExChannel),
            ok
    end.

delete_queue(QName, Connection) ->
    {ok, DelChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DelChannel, #'queue.delete'{queue=QName}) of
        #'queue.delete_ok'{} ->
            amqp_channel:close(DelChannel)
    end.

publish(Observer, VHost, Exchange, Key, Request) ->
    case init_connection(Observer, VHost) of
        {ok, Connection} -> publish0(Connection, VHost, Exchange, Key, Request);
        {error, access_refused} -> {error, forbidden, "Access Refused"}
    end.

publish0(Connection, _VHost, Exchange, Key, #coap_message{options=Options, payload=Payload}) ->
    {ok, PubChannel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(PubChannel, #'confirm.select'{}),

    BasicPublish = #'basic.publish'{exchange=Exchange,
                                    routing_key=Key,
                                    mandatory=true},
    Content = #amqp_msg{props = #'P_basic'{
                            content_type = proplists:get_value(content_format, Options),
                            delivery_mode = 1},
                        payload = Payload},
    amqp_channel:call(PubChannel, BasicPublish, Content),
    case catch amqp_channel:wait_for_confirms(PubChannel) of
        true ->
            amqp_channel:close(PubChannel),
            ok;
        % when the destination exchange does not exist
        {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
            {error, not_found, Error}
    end.

set_message_from_amqp(#'P_basic'{content_type=ContentType, expiration=Expires, message_id=MsgId}, Payload, Msg) ->
    % convert AMQP expires[milliseconds] to CoAP max-age[seconds]
    coap_message:set(max_age, if Expires == undefined -> undefined;
                                 true -> trunc(binary_to_integer(Expires)/1000)
                              end,
        % etag is the first 4 bytes of sha-hash
        coap_message:set(etag, if MsgId == undefined -> undefined;
                                  true -> binary:part(crypto:hash(sha, MsgId), {0,4})
                               end,
            coap_message:set(content_format, ContentType,
                coap_message:set_payload(Payload, Msg)))).

% end of file
