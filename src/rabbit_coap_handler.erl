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

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

% consumers map consumer-tag -> observer-addr
% observers map observer-addr -> sequence-num, consumer-tag
-record(state, {vhost, connection, channel, consumers, observers}).

start_link(VHost, Prefix) ->
    gen_server:start_link(?MODULE, [VHost, Prefix], []).

init([VHost, Prefix]) ->
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host=VHost}),

    coap_server_content:add_handler(self(), {absolute, Prefix, [{rt, "core.ps"}]}, true),
    gen_server:cast(self(), init_consuming_channel),

    State = #state{vhost=VHost, connection=Connection},
    {ok, State}.

handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(init_consuming_channel, State=#state{vhost=VHost, connection=Connection}) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),

    Queues = rabbit_amqqueue:list(VHost),
    % start consuming all existing observer queues
    {Consumers, Observers} = lists:foldl(
        fun (#amqqueue{name=Queue}, {Consumers, Observers}) ->
            #resource{name=QName} = Queue,
            case QName of
                <<"coap/", _Tail/binary>> ->
                    Observer = queue_to_observer(QName),
                    CTag = observe_queue(Channel, QName),
                    {dict:store(CTag, Observer, Consumers), dict:store(Observer, {0, CTag}, Observers)};
                _Else ->
                    {Consumers, Observers}
            end
        end, {dict:new(), dict:new()}, Queues),
    {noreply, State#state{channel=Channel, consumers=Consumers, observers=Observers}}.

handle_info({coap_request, Pid, Sender={_, PeerIP, PeerPort},
            Request=#coap_message{method='get', token=Token, options=Options}},
            State=#state{connection=Connection, channel=Channel, consumers=Consumers, observers=Observers}) ->
    Exchange = lists:last(proplists:get_value(uri_path, Options)),
    % each observer has assigned a queue
    Observer = {PeerIP, PeerPort, Token},
    QName = observer_to_queue(Observer),

    % get desired action
    Observe = case proplists:get_value(observe, Options) of
        [O] -> O;
        _Else -> undefined
    end,
    % get subscription status
    Seq = case dict:find(Observer, Observers) of
        {ok, {S, _}} -> S;
        error -> undefined
    end,

    if
        Observe == 0 -> % (re-)subscribe
            delete_queue(QName, Connection),
            case create_and_bind_queue(true, QName, list_to_binary(Exchange), Connection) of
                ok ->
                    CTag = observe_queue(Channel, QName),
                    Consumers2 = dict:store(CTag, Observer, Consumers),
                    Observers2 = dict:store(Observer,
                        {if Seq == undefined -> 0; true -> Seq end, CTag}, Observers),
                    coap_exchange:ack(Pid, Sender, Request),
                    {noreply, State#state{consumers=Consumers2, observers=Observers2}}
            end;

        Observe == 1; % (repeated) cancellation
        Seq == undefined -> % standard get
            delete_queue(QName, Connection),
            case create_and_bind_queue(false, QName, list_to_binary(Exchange), Connection) of
                ok ->
                    CTag = observe_queue(Channel, QName),
                    Consumers2 = dict:store(CTag, Observer, Consumers),
                    Observers2 = dict:erase(Observer, Observers),
                    coap_exchange:ack(Pid, Sender, Request),
                    {noreply, State#state{consumers=Consumers2, observers=Observers2}}
            end;

        true -> % standard get when subscribed
            coap_exchange:reply(Pid, Sender, Request, bad_option),
            {noreply, State}
    end;

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

% message delivery
handle_info({#'basic.deliver'{consumer_tag=CTag, delivery_tag=DTag}, Content},
        State=#state{connection=Connection, consumers=Consumers, observers=Observers}) ->
    {ok, Observer={PeerIP, PeerPortNo, Token}} = dict:find(CTag, Consumers),

    #amqp_msg{props=Properties, payload=Payload} = Content,
    #'P_basic'{content_type=ContentType} = Properties,
    Message = coap_message:con_with_content(ContentType, Payload, Token),

    case dict:find(Observer, Observers) of
        {ok, {Seq, CTag}} ->
            {SeqNum, NextSeq} = seq_num(Seq),
            Message2 = Message#coap_message{options=[{observe, [SeqNum]}]},
            coap_endpoint:start_exchange({coap_server, PeerIP, PeerPortNo}, {Observer, DTag}, Message2),
            Observers2 = dict:store(Observer, {NextSeq, CTag}, Observers),
            {noreply, State#state{observers=Observers2}};
        error ->
            delete_queue(observer_to_queue(Observer), Connection),
            coap_endpoint:start_exchange({coap_server, PeerIP, PeerPortNo}, {Observer, DTag}, Message),
            {noreply, State}
    end;

handle_info({coap_response, _Pid, _Sender, {_Observer, DTag}, #coap_message{type=ack}},
        State=#state{channel=Channel}) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = DTag}),
    {noreply, State};

handle_info({coap_response, _Pid, _Sender, {Observer, _DTag}, #coap_message{type=reset}},
        State=#state{connection=Connection}) ->
    QName = observer_to_queue(Observer),
    rabbit_log:warning("cannot deliver from: ~p", [QName]),

    % this will cancel the consumers, so 'basic.cancel' will be received
    delete_queue(QName, Connection),
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

handle_info({coap_request, Pid, Sender, Request=#coap_message{method='put', options=Options}},
            State=#state{connection=Connection}) ->
    {ok, PubChannel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(PubChannel, #'confirm.select'{}),
    Exchange = lists:last(proplists:get_value(uri_path, Options)),

    BasicPublish = #'basic.publish'{exchange = list_to_binary(Exchange),
                            mandatory = true},
    Content = #amqp_msg{props = #'P_basic'{
                            content_type = proplists:get_value(content_format, Options),
                            delivery_mode = 1},
                        payload = Request#coap_message.payload},
    amqp_channel:call(PubChannel, BasicPublish, Content),
    case catch amqp_channel:wait_for_confirms(PubChannel) of
        true ->
            coap_exchange:reply(Pid, Sender, Request, changed),
            amqp_channel:close(PubChannel);
        % when the destination exchange does not exist
        {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
            coap_exchange:reply(Pid, Sender, Request, not_found, Error)
    end,
    {noreply, State};

handle_info({coap_request, Pid, Sender, Request=#coap_message{method='post', payload=Payload}},
            State=#state{connection=Connection}) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    {ok, ExType} = application:get_env(rabbitmq_coap_pubsub, exchange_type),

    case core_link:decode(binary_to_list(Payload)) of
        [{rootless, [Exchange], _}] ->
            case catch amqp_channel:call(ExChannel,
                    #'exchange.declare'{exchange = list_to_binary(Exchange),
                                        durable = true,
                                        type = ExType}) of
                #'exchange.declare_ok'{} ->
                    coap_exchange:reply(Pid, Sender, Request, created),
                    amqp_channel:close(ExChannel);
                % when the exchange already exists with different parameters
                {'EXIT', {{shutdown, {server_initiated_close, 406, Error}}, _From}} ->
                    coap_exchange:reply(Pid, Sender, Request, forbidden, Error)
            end
    end,
    {noreply, State};

handle_info({coap_request, Pid, Sender, Request=#coap_message{method='delete', options=Options}},
            State=#state{vhost=VHost, connection=Connection}) ->
    {ok, ExChannel} = amqp_connection:open_channel(Connection),
    Exchange = lists:last(proplists:get_value(uri_path, Options)),
    ExchangeBin = list_to_binary(Exchange),

    % list bound queues
    Binds = rabbit_binding:list_for_source(rabbit_misc:r(VHost, exchange, ExchangeBin)),

    case catch amqp_channel:call(ExChannel,
            #'exchange.delete'{exchange = ExchangeBin}) of
        #'exchange.delete_ok'{} ->
            % remove all CoAP consumers bound to this exchange
            lists:foreach(
                fun(#binding{destination=Destination}) ->
                    #resource{name=QName}=Destination,
                    case QName of
                        <<"coap/", _Tail/binary>> ->
                            delete_queue(QName, Connection);
                        _Else ->
                            ok
                    end
                end, Binds),
            coap_exchange:reply(Pid, Sender, Request, deleted),
            amqp_channel:close(ExChannel)
    end,
    {noreply, State};

handle_info({coap_request, Pid, Sender, Request}, State) ->
    coap_exchange:reply(Pid, Sender, Request, method_not_allowed),
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

create_and_bind_queue(Durable, QName, Exchange, Connection) ->
    {ok, DecChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DecChannel, #'queue.declare'{queue=QName, durable=Durable}) of
        #'queue.declare_ok'{} ->
            case catch amqp_channel:call(DecChannel, #'queue.bind'{queue=QName, exchange=Exchange}) of
                #'queue.bind_ok'{} ->
                    amqp_channel:close(DecChannel),
                    ok
            end
    end.

observe_queue(Channel, QName) ->
    #'basic.consume_ok'{consumer_tag=Tag} = amqp_channel:call(Channel, #'basic.consume'{queue=QName}),
    Tag.

delete_queue(QName, Connection) ->
    {ok, DelChannel} = amqp_connection:open_channel(Connection),
    case catch amqp_channel:call(DelChannel, #'queue.delete'{queue=QName}) of
        #'queue.delete_ok'{} ->
            amqp_channel:close(DelChannel)
    end.


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
