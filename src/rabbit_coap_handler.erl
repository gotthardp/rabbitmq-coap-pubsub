%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_handler).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gen_coap/include/coap.hrl").
-include_lib("rabbitmq_lvc/include/rabbit_lvc_plugin.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

% consumers map consumer-tag -> observer-addr
% observers map observer-addr -> sequence-num, consumer-tag
-record(state, {vhost, prefix, connection, channel, consumers, observers}).

start_link(VHost, Prefix) ->
    gen_server:start_link(?MODULE, [VHost, Prefix], []).

init([VHost, Prefix]) ->
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host=VHost}),

    coap_server_content:add_handler(self(),
        [{absolute, Prefix, [{rt, "core.ps"}]},
         {absolute, Prefix++[exchange], []},
         {absolute, Prefix++[exchange, key], []}
        ]),
    gen_server:cast(self(), init_consuming_channel),

    State = #state{vhost=VHost, prefix=Prefix, connection=Connection},
    {ok, State}.

% DISCOVER
handle_call({get_links, {absolute, Uri, _}}, _From, State=#state{vhost=VHost, prefix=Prefix}) ->
    Suffix = lists:nthtail(length(Prefix), Uri),
    {reply, get_resources(VHost, Prefix, Suffix), State};
handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

% initialization and recovery of consumers
handle_cast(init_consuming_channel, State=#state{vhost=VHost, connection=Connection}) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    % start consuming all existing observer queues
    State2 = lists:foldl(
        fun (#amqqueue{name=#resource{name=QName}}, Acc) ->
            case QName of
                <<"coap/", _Tail/binary>> ->
                    observe_queue(queue_to_observer(QName), QName, Acc);
                _Else ->
                    Acc
            end
        end, State#state{channel=Channel, consumers=dict:new(), observers=dict:new()},
        rabbit_amqqueue:list(VHost)),
    {noreply, State2}.

% CREATE
handle_info({coap_request, _ChId, Pid, [], Request=#coap_message{method='post', payload=Payload}}, State) ->
    case core_link:decode(binary_to_list(Payload)) of
        [{rootless, [Exchange], _}] ->
            handle_create_topic(list_to_binary(Exchange), Pid, Request, State);
        _Else ->
            coap_request:reply(Pid, Request, {error, bad_request}),
            {noreply, State}
    end;

% REMOVE
handle_info({coap_request, _ChId, Pid, Match, Request=#coap_message{method='delete'}}, State) ->
    Exchange = get_match(exchange, Match),
    Key = get_match(key, Match),
    handle_delete_topic(Exchange, Key, Pid, Request, State);

% READ / SUBSCRIBE / UNSUBSCRIBE
handle_info({coap_request, {PeerIP, PeerPort}, Pid, Match,
            Request=#coap_message{method='get', token=Token, options=Options}},
            State=#state{connection=Connection}) ->
    Observer = {PeerIP, PeerPort, Token},
    Exchange = get_match(exchange, Match),
    Key = get_match(key, Match),
    % get desired action
    case proplists:get_value(observe, Options) of
        [0] ->
            % (re)subscribe
            handle_subscribe(Observer, Exchange, Key, Pid, Request, State);
        [1] ->
            % (repeated) cancellation
            delete_queue(observer_to_queue(Observer), Connection),
            handle_get(Exchange, Key, Pid, Request, State);
        undefined ->
            % standard get
            handle_get(Exchange, Key, Pid, Request, State);
        _SomethingWeird ->
            coap_exchange:reply(Pid, Request, {error, bad_option}),
            {noreply, State}
    end;

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

% subscription was cancelled
handle_info(#'basic.cancel'{consumer_tag=CTag}, State=#state{consumers=Consumers, observers=Observers}) ->
    {ok, Observer} = dict:find(CTag, Consumers),

    Consumers2 = dict:erase(CTag, Consumers),
    Observers2 = case dict:find(Observer, Observers) of
        {ok, {_, CTag}} ->
            rabbit_log:info("cancelled observer: ~p", [observer_to_queue(Observer)]),
            dict:erase(Observer, Observers);
        _Else ->
            Observers
    end,
    {noreply, State#state{consumers=Consumers2, observers=Observers2}};

% PUBLISH
handle_info({coap_request, _ChId, Pid, Match, Request=#coap_message{method='put'}}, State) ->
    Exchange = get_match(exchange, Match),
    Key = get_match(key, Match),
    handle_publish(Exchange, Key, Pid, Request, State);

% message delivery
handle_info({#'basic.deliver'{consumer_tag=CTag, delivery_tag=DTag},
             #amqp_msg{props = Props, payload = Payload}},
        State=#state{connection=Connection, consumers=Consumers, observers=Observers}) ->
    {ok, Observer={PeerIP, PeerPortNo, Token}} = dict:find(CTag, Consumers),
    {ok, Pid} = coap_udp_socket:get_channel(coap_server, {PeerIP, PeerPortNo}),

    Message = content_from_amqp(Props, Payload, #coap_message{type=con, token=Token}),
    case dict:find(Observer, Observers) of
        {ok, {Seq, CTag}} ->
            {SeqNum, NextSeq} = seq_num(Seq),
            {ok, _} = coap_channel:send_message(Pid,
                Message#coap_message{options=[{observe, [SeqNum]}]}, {Observer, DTag}),
            Observers2 = dict:store(Observer, {NextSeq, CTag}, Observers),
            {noreply, State#state{observers=Observers2}};
        error ->
            delete_queue(observer_to_queue(Observer), Connection),
            {noreply, State}
    end;

handle_info({coap_ack, _ChId, _Pid, {_Observer, DTag}},
        State=#state{channel=Channel}) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = DTag}),
    {noreply, State};

handle_info({coap_error, _ChId, _Pid, {Observer, _DTag}, _Error},
        State=#state{connection=Connection}) ->
    % this will cancel the consumers, so 'basic.cancel' will be received
    delete_queue(observer_to_queue(Observer), Connection),
    {noreply, State};

handle_info({coap_request, _ChId, Pid, _Match, Request}, State) ->
    coap_request:reply(Pid, Request, {error, method_not_allowed}),
    {noreply, State};

handle_info(Msg, State) ->
    rabbit_log:warning("unexpected message ~p", [Msg]),
    {noreply, State}.


terminate(_Reason, #state{connection=Connection, channel=Channel}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


% utility functions

% in the init we registered two templates, so we get called twice,
% but we load all resources in one select
get_resources(VHost, Prefix, [exchange]) ->
    [];
get_resources(VHost, Prefix, [exchange, key]) ->
    lists:map(
        fun ({Exch, RK, Content}) -> construct_link(Prefix, Exch, RK, Content) end,
        mnesia:dirty_select(?LVC_TABLE,
            [{{cached,{cachekey,{resource,VHost,exchange,'$1'},'$2'},'$3'},
                [], [{{'$1', '$2', '$3'}}]}])).

construct_link(Prefix, Exch, <<>>, Content) ->
    {absolute, Prefix++[binary_to_list(Exch)], construct_attributes(Content)};
construct_link(Prefix, Exch, RK, Content) ->
    {absolute, Prefix++[binary_to_list(Exch), binary_to_list(RK)], construct_attributes(Content)}.

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


handle_create_topic(Exchange, Pid, Request, State=#state{connection=Connection}) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(ExChannel,
            #'exchange.declare'{exchange = Exchange,
                                durable = true,
                                type = <<"x-lvc">>}) of
        #'exchange.declare_ok'{} ->
            coap_request:reply(Pid, Request, {ok, created}),
            amqp_channel:close(ExChannel);
        % when the exchange already exists with different parameters
        {'EXIT', {{shutdown, {server_initiated_close, 406, Error}}, _From}} ->
            coap_request:reply(Pid, Request, {error, forbidden}, Error)
    end,
    {noreply, State}.

handle_delete_topic(Exchange, <<>>, Pid, Request, State=#state{vhost=VHost, connection=Connection}) ->
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
            coap_request:reply(Pid, Request, {ok, deleted}),
            amqp_channel:close(ExChannel)
    end,
    {noreply, State}.

handle_get(Exchange, Key, Pid, Request, State=#state{vhost=VHost}) ->
    case mnesia:dirty_read(?LVC_TABLE,
            #cachekey{exchange=rabbit_misc:r(VHost, exchange, Exchange),
                      routing_key=Key}) of
        [] ->
            coap_request:reply(Pid, Request, {error, not_found});
        [#cached{content=#basic_message{content=Content}}] ->
            {Props, Payload} = rabbit_basic:from_content(Content),
            coap_channel:send_ack(Pid,
                content_from_amqp(Props, Payload, coap_message:response(Request)))
    end,
    {noreply, State}.

handle_subscribe(Observer, Exchange, Key, Pid, Request, State=#state{connection=Connection}) ->
    QName = observer_to_queue(Observer),
    delete_queue(QName, Connection),
    case create_and_bind_queue(QName, Exchange, Key, Connection) of
        ok ->
            coap_request:ack(Pid, Request),
            {noreply, observe_queue(Observer, QName, State)};
        {error, Error} ->
            coap_request:reply(Pid, Request, {error, not_found}, Error),
            {noreply, State}
    end.

create_and_bind_queue(QName, Exchange, Key, Connection) ->
    {ok, DecChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DecChannel, #'queue.declare'{queue=QName, durable=true}) of
        #'queue.declare_ok'{} ->
            case catch amqp_channel:call(DecChannel, #'queue.bind'{queue=QName,
                                                                   exchange=Exchange,
                                                                   routing_key=Key}) of
                #'queue.bind_ok'{} ->
                    amqp_channel:close(DecChannel),
                    ok;
                {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
                    {error, Error}
            end
    end.

observe_queue(Observer, QName, State=#state{channel=Channel, consumers=Consumers, observers=Observers}) ->
    % get subscription status
    Seq = case dict:find(Observer, Observers) of
        {ok, {S, _}} -> S;
        error -> undefined
    end,
    #'basic.consume_ok'{consumer_tag=CTag} = amqp_channel:call(Channel, #'basic.consume'{queue=QName}),
    Consumers2 = dict:store(CTag, Observer, Consumers),
    Observers2 = dict:store(Observer, {if Seq == undefined -> 0; true -> Seq end, CTag}, Observers),
    State#state{consumers=Consumers2, observers=Observers2}.

delete_queue(QName, Connection) ->
    {ok, DelChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DelChannel, #'queue.delete'{queue=QName}) of
        #'queue.delete_ok'{} ->
            amqp_channel:close(DelChannel)
    end.

content_from_amqp(#'P_basic'{content_type=ContentType, expiration=Expires, message_id=MsgId}, Payload, Msg) ->
    coap_message:content(ContentType, Payload,
        set_expiration(Expires,
            set_mid(MsgId, Msg))).

set_expiration(undefined, Message) ->
    Message;
set_expiration(Expiration, Message=#coap_message{options=Options}) ->
    Message#coap_message{options=[{max_age, [binary_to_integer(Expiration)]}|Options]}.

set_mid(undefined, Message) ->
    Message;
set_mid(MsgId, Message=#coap_message{options=Options}) ->
    Hash = crypto:hash(sha, MsgId),
    Message#coap_message{options=[{etag, [binary:part(Hash, {0,4})]}|Options]}.

get_match(Id, Match) ->
    list_to_binary(proplists:get_value(Id, Match, "")).

handle_publish(Exchange, Key, Pid, Request=#coap_message{options=Options, payload=Payload},
        State=#state{connection=Connection}) ->
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
            coap_request:reply(Pid, Request, {ok, changed}),
            amqp_channel:close(PubChannel);
        % when the destination exchange does not exist
        {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
            coap_request:reply(Pid, Request, {error, not_found}, Error)
    end,
    {noreply, State}.


observer_to_queue({PeerIP, PeerPort, Token}) ->
    Str = lists:concat(["coap/", inet:ntoa(PeerIP), ":", PeerPort, "/"]),
    % stackoverflow.com/questions/3768197/erlang-ioformatting-a-binary-to-hex
    % a little magic from http://stackoverflow.com/users/2760050/himangshuj
    TokenStr = << <<Y>> ||<<X:4>> <= Token, Y <- integer_to_list(X,16)>>,
    <<(list_to_binary(Str))/binary, TokenStr/binary>>.

queue_to_observer(Binary) ->
    [<<"coap">>, IPStr, PortStr, TokenStr] = binary:split(Binary, [<<"/">>, <<":">>], [global]),
    {ok, PeerIP} = inet:parse_address(binary_to_list(IPStr)),
    PeerPort = list_to_integer(binary_to_list(PortStr)),
    Token = <<<<Z>> || <<X:8,Y:8>> <= TokenStr, Z <- [binary_to_integer(<<X,Y>>,16)]>>,
    {PeerIP, PeerPort, Token}.

seq_num(Seq) ->
    {_, Secs, _} = os:timestamp(),
    % keep the sequence increasing even after reboot, avoiding a persistent database
    % this sequence will wrap in 68 hours (4095 seconds) and allows us
    % to send up to 4095 messages/s to a single endpoint
    SeqNum = ((Secs band 16#0FFF) bsl 12) bor (Seq band 16#0FFF),
    NextSeq = if
        Seq < 16#0FFF -> Seq+1;
        true -> 0
    end,
    {SeqNum, NextSeq}.

% end of file
