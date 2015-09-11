%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_amqp_consumer_sup).
-behaviour(supervisor).

-export([start_link/0, start_consumer/4, restart_consumer/4, stop_consumer/1, init/1]).

start_link() ->
    Res = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    [start_consumer(Observer, VHost, Exchange, Key) ||
        {Observer, {VHost, Exchange, Key}} <- rabbit_coap_amqp_consumer:all()],
    Res.

start_consumer(Observer, VHost, Exchange, Key) ->
    supervisor:start_child(?MODULE,
        {Observer,
            {rabbit_coap_amqp_consumer, start_link, [Observer, VHost, Exchange, Key]},
            transient, 5000, worker, []}).

restart_consumer(Observer, VHost, Exchange, Key) ->
    case start_consumer(Observer, VHost, Exchange, Key) of
        {error, {already_started, ConsumerPid}} ->
            ok = supervisor:terminate_child(?MODULE, ConsumerPid),
            ok = supervisor:delete_child(?MODULE, Observer),
            start_consumer(Observer, VHost, Exchange, Key);
        Otherwise ->
            Otherwise
    end.

stop_consumer(Observer) ->
    ok = supervisor:terminate_child(?MODULE, Observer),
    ok = supervisor:delete_child(?MODULE, Observer).

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.

% end of file
