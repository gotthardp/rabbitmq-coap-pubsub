%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_amqp_consumer).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("gen_coap/include/coap.hrl").
-include_lib("rabbitmq_lvc/include/rabbit_lvc_plugin.hrl").

-export([start_link/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-export([setup_schema/0, disable_plugin/0, all/0]).

-rabbit_boot_step({?MODULE,
                   [{description, "CoAP publishers"},
                    {mfa, {?MODULE, setup_schema, []}},
                    {cleanup, {?MODULE, disable_plugin, []}},
                    {enables, recovery}]}).

-record(coap_observer, {observer, resource, seq}).

-record(state, {observer, connection, channel}).

setup_schema() ->
    mnesia:create_table(coap_observer,
                        [{attributes, record_info(fields, coap_observer)},
                         {disc_copies, [node()]},
                         {type, set}]),
    mnesia:wait_for_tables([coap_observer], 30000),
    ok.

disable_plugin() ->
    mnesia:delete_table(coap_observer),
    ok.

all() ->
    mnesia:dirty_select(coap_observer, [{{coap_observer, '$1', '$2', '_'}, [], [{{'$1', '$2'}}]}]).


start_link(Observer, VHost, Exchange, Key) ->
    gen_server:start_link(?MODULE, [Observer, VHost, Exchange, Key], []).

% initialization
init([Observer, VHost, Exchange, Key]) ->
    rabbit_misc:execute_mnesia_transaction(
        fun () ->
            case mnesia:read(coap_observer, Observer) of
                [] ->
                    mnesia:write(#coap_observer{observer=Observer, resource={VHost, Exchange, Key}, seq=0});
                [#coap_observer{}=Record] ->
                    mnesia:write(Record#coap_observer{resource={VHost, Exchange, Key}})
            end
        end),
    case rabbit_coap_amqp_client:init_connection(Observer, VHost) of
        {ok, Connection} ->
            init_consumer(Observer, Connection, Exchange, Key);
        {error, access_refused} ->
            {stop, {forbidden, "Refused"}};
        {error, {auth_failure, Error}} ->
            {stop, {forbidden, Error}}
    end.

init_consumer(Observer, Connection, Exchange, Key) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    QName = observer_to_queue(Observer),
    {ok, DecChannel} = amqp_connection:open_channel(Connection),
    % create and bind the consumer queue
    case catch amqp_channel:call(DecChannel, #'queue.declare'{queue=QName}) of
        #'queue.declare_ok'{} ->
            case catch amqp_channel:call(DecChannel, #'queue.bind'{queue=QName,
                                                                   exchange=Exchange,
                                                                   routing_key=Key}) of
                #'queue.bind_ok'{} ->
                    amqp_channel:close(DecChannel),
                    #'basic.consume_ok'{} = amqp_channel:call(Channel, #'basic.consume'{queue=QName}),
                    {ok, #state{observer=Observer, connection=Connection, channel=Channel}};
                {'EXIT', {{shutdown, {server_initiated_close, 404, Error}}, _From}} ->
                    {stop, {not_found, Error}}
            end
    end.

handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.


% message consumption
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info(#'basic.cancel'{}, State=#state{observer=Observer}) ->
    rabbit_log:info("cancelled observer: ~p", [Observer]),
    {stop, normal, State};

handle_info({#'basic.deliver'{delivery_tag=DTag}, #amqp_msg{props = Props, payload = Payload}},
        State=#state{observer={PeerIP, PeerPortNo, Token}=Observer}) ->
    {ok, Pid} = coap_udp_socket:get_channel(coap_server, {PeerIP, PeerPortNo}),

    Message = rabbit_coap_amqp_client:set_message_from_amqp(Props, Payload,
        coap_message:new(con, Token, {ok, content})),
    {ok, _} = coap_channel:send_message(Pid,
        Message#coap_message{options=[{observe, [next_seq(Observer)]}]}, {DTag}),
    {noreply, State};


handle_info({coap_ack, _ChId, _Pid, {DTag}},
        State=#state{channel=Channel}) ->
    amqp_channel:cast(Channel, #'basic.ack'{delivery_tag = DTag}),
    {noreply, State};

handle_info({coap_error, _ChId, _Pid, {_DTag}, _Error}, State) ->
    {stop, normal, State};

handle_info(Msg, State) ->
    rabbit_log:warning("unexpected message ~p", [Msg]),
    {noreply, State}.


terminate(normal, State=#state{observer=Observer, channel=Channel}) ->
    mnesia:dirty_delete(coap_observer, Observer),
    catch amqp_channel:call(Channel, #'queue.delete'{queue=observer_to_queue(Observer)}),
    % inform our supervisor that we are done
    timer:apply_after(0, supervisor, delete_child, [rabbit_coap_amqp_consumer_sup, Observer]),
    close(State);
terminate(_Reason, State) ->
    close(State).

close(#state{connection=Connection, channel=Channel}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


% utility functions

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

next_seq(Observer) ->
    rabbit_misc:execute_mnesia_transaction(
        fun () ->
            [#coap_observer{seq=Seq}=Record] = mnesia:read(coap_observer, Observer),
            mnesia:write(Record#coap_observer{seq=if
                                                      Seq < 16#0FFF -> Seq+1;
                                                      true -> 0
                                                  end}),
            Seq
        end).


% end of file
