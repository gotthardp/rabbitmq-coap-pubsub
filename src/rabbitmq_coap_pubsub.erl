%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbitmq_coap_pubsub).
-export([init_plugin/0]).

-rabbit_boot_step({?MODULE,
                   [{description, "CoAP interface"},
                    {mfa, {?MODULE, init_plugin, []}}
                   ]}).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.

init_plugin() ->
    {ok, Prefix} = application:get_env(?MODULE, prefix),
    ensure_started(gen_coap),
    coap_server_registry:add_handler(Prefix, rabbit_coap_handler, []),
    ok.

% end of file
