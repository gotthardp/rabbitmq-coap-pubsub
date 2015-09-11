%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbitmq_coap_pubsub).

-behaviour(application).
-export([start/2, stop/1]).

-behaviour(supervisor).
-export([init/1]).

start(normal, []) ->
    supervisor:start_link(?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    {ok, Prefix} = application:get_env(?MODULE, prefix),
    coap_server_content:add_handler(Prefix, rabbit_coap_handler, []),
    {ok, {{one_for_one, 3, 10},
            [{rabbit_coap_amqp_consumer_sup, {rabbit_coap_amqp_consumer_sup, start_link, []},
                permanent, infinity, supervisor, []}]}}.

% end of file
