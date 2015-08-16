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
    supervisor:start_link(?MODULE, _Arg = []).

stop(_State) ->
    ok.

init([]) ->
    {ok, Resources} = application:get_env(?MODULE, resources),
    {ok, {{one_for_one, 3, 10},
        lists:foldl(
            fun({VHost, Prefix}, Acc) ->
                [{coap_handler, {rabbit_coap_handler, start_link, [VHost, Prefix]},
                    permanent, 10000, worker, [rabbit_coap_handler]} | Acc]
            end, [], Resources)}}.

% end of file
