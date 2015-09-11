%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_handler).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gen_coap/include/coap.hrl").
-include_lib("rabbitmq_lvc/include/rabbit_lvc_plugin.hrl").

-export([coap_discover/2, coap_get/4, coap_subscribe/4, coap_unsubscribe/4,
    coap_post/4, coap_put/4, coap_delete/4]).

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
coap_get(_ChId, Channel, [VHost, Exchange], Request) ->
    handle_get(VHost, Exchange, <<>>, Channel, Request);
coap_get(_ChId, Channel, [VHost, Exchange, Key], Request) ->
    handle_get(VHost, Exchange, Key, Channel, Request);
coap_get(_ChId, Channel, _Else, Request) ->
    coap_request:reply(Channel, Request, {error, not_found}).

handle_get(VHost, Exchange, Key, Channel, Request) ->
    case rabbit_access_control:check_user_login(<<"anonymous">>, []) of
        {ok, User} -> handle_get(User, VHost, Exchange, Key, Channel, Request);
        {refused,_,_,_} -> coap_request:reply(Channel, Request, {error, forbidden})
    end.

handle_get(User, VHost, Exchange, Key, Channel, Request) ->
    case catch rabbit_access_control:check_resource_access(User, rabbit_misc:r(VHost, exchange, Exchange), read) of
        ok ->
            case mnesia:dirty_read(?LVC_TABLE,
                    #cachekey{exchange=rabbit_misc:r(VHost, exchange, Exchange),
                              routing_key=Key}) of
                [] ->
                    coap_request:reply(Channel, Request, {error, not_found});
                [#cached{content=#basic_message{content=Content}}] ->
                    {Props, Payload} = rabbit_basic:from_content(Content),
                    coap_channel:send_ack(Channel,
                        rabbit_coap_amqp_client:set_message_from_amqp(Props, Payload,
                            coap_message:response({ok, content}, Request)))
            end;
        {'EXIT', _} ->
            coap_request:reply(Channel, Request, {error, forbidden})
    end.

% SUBSCRIBE
coap_subscribe({PeerIP, PeerPort}, Channel, [VHost, Exchange], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_subscribe(Observer, VHost, Exchange, <<>>, Channel, Request);
coap_subscribe({PeerIP, PeerPort}, Channel, [VHost, Exchange, Key], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_subscribe(Observer, VHost, Exchange, Key, Channel, Request).

handle_subscribe(Observer, VHost, Exchange, Key, Channel, Request) ->
    case rabbit_coap_amqp_consumer_sup:restart_consumer(Observer, VHost, Exchange, Key) of
        {ok, _ConsumerPid} ->
            coap_request:ack(Channel, Request);
        {error, {{Code, Error}, _ChildSpec}} ->
            coap_request:reply(Channel, Request, {error, Code}, Error);
        {error, {Error, _ChildSpec}} ->
            coap_request:reply(Channel, Request, {error, internal_server_error},
                lists:flatten(io_lib:format("~p",[Error])))
    end.

% UNSUBSCRIBE
coap_unsubscribe({PeerIP, PeerPort}, Channel, [VHost, Exchange], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_unsubscribe(Observer, VHost, Exchange, <<>>, Channel, Request);
coap_unsubscribe({PeerIP, PeerPort}, Channel, [VHost, Exchange, Key], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_unsubscribe(Observer, VHost, Exchange, Key, Channel, Request).

handle_unsubscribe(Observer, VHost, Exchange, Key, Channel, Request) ->
    rabbit_coap_amqp_consumer_sup:stop_consumer(Observer),
    handle_get(VHost, Exchange, Key, Channel, Request).

% CREATE
coap_post({PeerIP, PeerPort}, Channel, [VHost], Request=#coap_message{token=Token, payload=Payload}) ->
    Observer = {PeerIP, PeerPort, Token},
    case core_link:decode(Payload) of
        [{rootless, [Exchange], _}] ->
            handle_create_topic(Observer, VHost, Exchange, Channel, Request);
        _Else ->
            coap_request:reply(Channel, Request, {error, bad_request})
    end;
coap_post(_ChId, Channel, _Else, Request) ->
    coap_request:reply(Channel, Request, {error, forbidden}).

handle_create_topic(Observer, VHost, Exchange, Channel, Request) ->
    case rabbit_coap_amqp_client:create_topic(Observer, VHost, Exchange) of
        ok ->
            coap_request:reply(Channel, Request, {ok, created});
        {error, Error, Text} ->
            coap_request:reply(Channel, Request, {error, Error}, Text)
    end.

% DELETE
coap_delete({PeerIP, PeerPort}, Channel, [VHost, Exchange], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_delete_topic(Observer, VHost, Exchange, Channel, Request);
coap_delete(_ChId, Channel, _Else, Request) ->
    coap_request:reply(Channel, Request, {error, not_found}).

handle_delete_topic(Observer, VHost, Exchange, Channel, Request) ->
    case rabbit_coap_amqp_client:delete_topic(Observer, VHost, Exchange) of
        ok ->
            coap_request:reply(Channel, Request, {ok, deleted});
        {error, Error, Text} ->
            coap_request:reply(Channel, Request, {error, Error}, Text)
    end.

% PUBLISH
coap_put({PeerIP, PeerPort}, Channel, [VHost, Exchange], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_publish(Observer, VHost, Exchange, "", Channel, Request);
coap_put({PeerIP, PeerPort}, Channel, [VHost, Exchange, Key], Request=#coap_message{token=Token}) ->
    Observer = {PeerIP, PeerPort, Token},
    handle_publish(Observer, VHost, Exchange, Key, Channel, Request);
coap_put(_ChId, Channel, _Else, Request) ->
    coap_request:reply(Channel, Request, {error, not_found}).

handle_publish(Observer, VHost, Exchange, Key, Channel, Request) ->
    case rabbit_coap_amqp_client:publish(Observer, VHost, Exchange, Key, Request) of
        ok ->
            coap_request:reply(Channel, Request, {ok, changed});
        {error, Error, Text} ->
            coap_request:reply(Channel, Request, {error, Error}, Text)
    end.


% utility functions

construct_link(Prefix, VHost, Exch, <<>>, Content) ->
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


% end of file
