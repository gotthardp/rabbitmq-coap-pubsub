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

-export([init_connection/2, with_connection/3, create_topic/3, delete_topic/3,
    create_and_bind_queue/4, publish/5, message_to_content/2]).

init_connection({PeerIP, PeerPortNo}, VHost) ->
    amqp_connection:start(
        #amqp_params_direct{username = <<"anonymous">>,
                            virtual_host = VHost,
                            adapter_info = #amqp_adapter_info{protocol  = {'CoAP', "1"},
                                                              name      = list_to_binary(lists:concat(["udp/", inet:ntoa(PeerIP), ":", PeerPortNo])),
                                                              peer_host = PeerIP,
                                                              peer_port = PeerPortNo}}).

with_connection(ChId, VHost, Fun) ->
    Connection = init_connection(ChId, VHost),
    Res = apply(Fun, [Connection]),
    case Connection of
        {ok, Conn} -> amqp_connection:close(Conn);
        _Else -> ok
    end,
    Res.

create_topic(ChId, VHost, Exchange) ->
    with_connection(ChId, VHost,
        fun ({ok, Connection}) -> create_topic0(Connection, VHost, Exchange);
            ({error, access_refused}) ->
                rabbit_log:warning("User ~p cannot access VHost ~p.~n", [ChId, VHost]),
                {error, forbidden, "Access Refused"}
        end).

create_topic0(Connection, _VHost, Exchange) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(ExChannel,
            #'exchange.declare'{exchange = Exchange,
                                durable = true,
                                type = <<"x-lvc">>}) of
        #'exchange.declare_ok'{} ->
            amqp_channel:close(ExChannel),
            {ok, created, #coap_content{}};
        % when the exchange already exists with different parameters
        {'EXIT', {{shutdown, {server_initiated_close, 406, Error}}, _From}} ->
            {error, forbidden, Error}
    end.

delete_topic(ChId, VHost, Exchange) ->
    with_connection(ChId, VHost,
        fun ({ok, Connection}) -> delete_topic0(Connection, VHost, Exchange);
            ({error, access_refused}) -> {error, forbidden, "Access Refused"}
        end).

delete_topic0(Connection, VHost, Exchange) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(ExChannel,
            #'exchange.delete'{exchange = Exchange}) of
        #'exchange.delete_ok'{} ->
            % remove all CoAP consumers bound to this exchange
            lists:foreach(
                fun (#binding{destination=#resource{kind=queue,
                                                    name= <<"coap/", _Tail/binary>>=QName}}) ->
                        delete_queue(QName, Connection);
                    (_Other) ->
                        ok
                end,
                rabbit_binding:list_for_source(rabbit_misc:r(VHost, exchange, Exchange))),
            amqp_channel:close(ExChannel),
            ok
    end.

create_and_bind_queue(Connection, QName, Exchange, Key) ->
    {ok, DecChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DecChannel, #'queue.declare'{queue=QName}) of
        #'queue.declare_ok'{} ->
            case catch amqp_channel:call(DecChannel, #'queue.bind'{queue=QName,
                                                                   exchange=Exchange,
                                                                   routing_key=Key}) of
                #'queue.bind_ok'{} ->
                    amqp_channel:close(DecChannel),
                    ok;
                {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
                    {error, not_found, Error}
            end
    end.

delete_queue(QName, Connection) ->
    {ok, DelChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DelChannel, #'queue.delete'{queue=QName}) of
        #'queue.delete_ok'{} ->
            amqp_channel:close(DelChannel)
    end.

publish(ChId, VHost, Exchange, Key, Content) ->
    with_connection(ChId, VHost,
        fun ({ok, Connection}) -> publish0(Connection, VHost, Exchange, Key, Content);
            ({error, access_refused}) -> {error, forbidden, "Access Refused"}
        end).

publish0(Connection, _VHost, Exchange, Key,
        #coap_content{etag=ETag, max_age=MaxAge, format=ContentFormat, payload=Payload}) ->
    {ok, PubChannel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(PubChannel, #'confirm.select'{}),

    BasicPublish = #'basic.publish'{exchange=Exchange,
                                    routing_key=Key,
                                    mandatory=true},
    Content = #amqp_msg{props = #'P_basic'{
                            content_type = ContentFormat,
                            expiration = integer_to_binary(MaxAge*1000), % milliseconds
                            message_id = ETag,
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

message_to_content(#'P_basic'{content_type=ContentType, expiration=Expires, message_id=MsgId}, Payload) ->
    #coap_content{
        % etag is the first 4 bytes of sha-hash
        etag = if MsgId == undefined -> undefined;
                  byte_size(MsgId) =< 8 -> MsgId;
                  true -> binary:part(crypto:hash(sha, MsgId), {0,4})
               end,
        % convert AMQP expires[milliseconds] to CoAP max-age[seconds]
        max_age = if Expires == undefined -> ?DEFAULT_MAX_AGE;
                     true -> trunc(binary_to_integer(Expires)/1000)
                  end,
        format = ContentType,
        payload = Payload}.

% end of file
