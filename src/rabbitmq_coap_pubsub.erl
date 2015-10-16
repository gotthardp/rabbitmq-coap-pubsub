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

init_plugin() ->
    {ok, Prefix} = application:get_env(?MODULE, prefix),
    coap_server_registry:add_handler(Prefix, rabbit_coap_handler, []),
    ok.

% end of file
