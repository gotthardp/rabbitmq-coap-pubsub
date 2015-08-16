%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
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
