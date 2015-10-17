%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_handler).
-behaviour(coap_resource).

-export([coap_discover/2, coap_get/3, coap_post/4, coap_put/4, coap_delete/3,
    coap_observe/3, coap_unobserve/1, handle_info/2, coap_ack/2]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gen_coap/include/coap.hrl").
-include_lib("rabbitmq_lvc/include/rabbit_lvc_plugin.hrl").

-record(obstate, {connection, channel, last_update}).

% DISCOVER
coap_discover(Prefix, _Args) ->
    case rabbit_access_control:check_user_login(<<"anonymous">>, []) of
        {ok, User} -> [{absolute, Prefix, [{rt, <<"core.ps">>}]}|get_resources(User, Prefix)];
        {refused,_,_,_} -> []
    end.

get_resources(User, Prefix) ->
    lists:filtermap(
        fun ({VHost, Exch, RK, Content}) ->
            case catch rabbit_access_control:check_resource_access(User, rabbit_misc:r(VHost, exchange, Exch), read) of
                ok -> {true, construct_link(Prefix, VHost, Exch, RK, Content)};
                {'EXIT', _} -> false
            end
        end,
        mnesia:dirty_select(?LVC_TABLE,
            [{{cached,{cachekey,{resource,'$1',exchange,'$2'},'$3'},'$4'},
                [], [{{'$1', '$2', '$3', '$4'}}]}])).

% GET
coap_get(_ChId, _Prefix, [VHost, Exchange]) ->
    handle_get(VHost, Exchange, undefined);
coap_get(_ChId, _Prefix, [VHost, Exchange, Key]) ->
    handle_get(VHost, Exchange, Key);
coap_get(_ChId, _Prefix, _Else) ->
    {error, not_found}.

handle_get(VHost, Exchange, Key) ->
    case rabbit_access_control:check_user_login(<<"anonymous">>, []) of
        {ok, User} -> handle_get(User, VHost, Exchange, Key);
        {refused,_,_,_} -> {error, forbidden}
    end.

handle_get(User, VHost, Exchange, Key) ->
    case catch rabbit_access_control:check_resource_access(User, rabbit_misc:r(VHost, exchange, Exchange), read) of
        ok ->
            case mnesia:dirty_read(?LVC_TABLE,
                    #cachekey{exchange=rabbit_misc:r(VHost, exchange, Exchange),
                              routing_key=Key}) of
                [] ->
                    {error, not_found};
                [#cached{content=#basic_message{content=Content}}] ->
                    {Props, Payload} = rabbit_basic:from_content(Content),
                    rabbit_coap_amqp_client:message_to_content(Props, Payload)
            end;
        {'EXIT', _} ->
            {error, forbidden}
    end.

% CREATE
coap_post(ChId, _Prefix, [VHost], #coap_content{payload=Payload}) ->
    case core_link:decode(Payload) of
        [{rootless, [Exchange], _}] -> rabbit_coap_amqp_client:create_topic(ChId, VHost, Exchange);
        _Else -> {error, bad_request}
    end;
coap_post(_ChId, _Prefix, _Else, _Content) ->
    {error, forbidden}.

% PUBLISH
coap_put(ChId, _Prefix, [VHost, Exchange], Content) ->
    rabbit_coap_amqp_client:publish(ChId, VHost, Exchange, undefined, Content);
coap_put(ChId, _Prefix, [VHost, Exchange, Key], Content) ->
    rabbit_coap_amqp_client:publish(ChId, VHost, Exchange, Key, Content);
coap_put(_ChId, _Prefix, _Else, _Content) ->
    {error, not_found}.

% DELETE
coap_delete(ChId, _Prefix, [VHost, Exchange]) ->
    rabbit_coap_amqp_client:delete_topic(ChId, VHost, Exchange);
coap_delete(_ChId, _Prefix, _Else) ->
    {error, not_found}.

% SUBSCRIBE
coap_observe(ChId, _Prefix, [VHost, Exchange]) ->
    handle_observe(ChId, VHost, Exchange, undefined);
coap_observe(ChId, _Prefix, [VHost, Exchange, Key]) ->
    handle_observe(ChId, VHost, Exchange, Key).

handle_observe(ChId, VHost, Exchange, Key) ->
    case rabbit_coap_amqp_client:init_connection(ChId, VHost) of
        {ok, Connection} ->
            QName = observer_to_queue(ChId),
            case rabbit_coap_amqp_client:create_and_bind_queue(Connection, QName, Exchange, Key) of
                ok ->
                    {ok, Channel} = amqp_connection:open_channel(Connection),
                    #'basic.consume_ok'{} = amqp_channel:call(Channel, #'basic.consume'{queue=QName}),
                    {ok, #obstate{connection=Connection, channel=Channel}};
                Error ->
                    Error
            end;
        {error, access_refused} ->
            {error, forbidden, "Refused"};
        {error, {auth_failure, Error}} ->
            {error, forbidden, Error}
    end.

% UNSUBSCRIBE
coap_unobserve(#obstate{connection=Connection, channel=Channel}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

% amqp consumer started
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State#obstate{last_update=undefined}};
% amqp consumer stopped, e.g. because its queue was purged
handle_info(#'basic.cancel'{}, State) ->
    rabbit_log:info("cancelled observer"),
    {stop, State};
% new message received
handle_info({#'basic.deliver'{}, Message=#amqp_msg{}}, State=#obstate{last_update=undefined}) ->
    % ignore the first update, which is sent just after binding the exchange
    {noreply, State#obstate{last_update=Message}};
handle_info({#'basic.deliver'{delivery_tag=DTag}, Message=#amqp_msg{props=Props, payload=Payload}}, State) ->
    {notify, DTag, rabbit_coap_amqp_client:message_to_content(Props, Payload),
        State#obstate{last_update=Message}};
% something else
handle_info(Msg, State) ->
    rabbit_log:warning("unexpected message ~p", [Msg]),
    {noreply, State}.

coap_ack(DTag, State=#obstate{channel=Channel}) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = DTag}),
    {ok, State}.


% utility functions

construct_link(Prefix, VHost, Exch, undefined, Content) ->
    {absolute, Prefix++[VHost, Exch], construct_attributes(Content)};
construct_link(Prefix, VHost, Exch, RK, Content) ->
    {absolute, Prefix++[VHost, Exch, RK], construct_attributes(Content)}.

construct_attributes(#basic_message{content=Content}) ->
    {#'P_basic'{content_type=ContentType}, Payload} = rabbit_basic:from_content(Content),
    create_ct_attr(ContentType,
        create_sz_attr(Payload, [])).

create_ct_attr(undefined, Acc) ->
    Acc;
create_ct_attr(ContentType, Acc) ->
    [{ct, ContentType}|Acc].

% do not display the size for small resources
create_sz_attr(Content, Acc) when size(Content) < 1280 ->
    Acc;
create_sz_attr(Content, Acc) ->
    [{sz, size(Content)}|Acc].

observer_to_queue({PeerIP, PeerPort}) ->
    Str = lists:concat(["coap/", inet:ntoa(PeerIP), ":", PeerPort]),
    list_to_binary(Str).

queue_to_observer(Binary) ->
    [<<"coap">>, IPStr, PortStr] = binary:split(Binary, [<<"/">>, <<":">>], [global]),
    {ok, PeerIP} = inet:parse_address(binary_to_list(IPStr)),
    PeerPort = list_to_integer(binary_to_list(PortStr)),
    {PeerIP, PeerPort}.

% end of file
