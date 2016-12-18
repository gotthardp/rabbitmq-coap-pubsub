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
    {ok, _} = application:ensure_all_started(gen_coap),
    case application:get_env(?MODULE, udp_listen) of
        {ok, UdpPort} when is_integer(UdpPort) ->
            {ok, _} = coap_server:start_udp(coap_udp_socket, UdpPort);
        undefined ->
            ok
    end,
    case application:get_env(?MODULE, dtls_listen) of
        {ok, DtlsPort} when is_integer(DtlsPort) ->
            DtlsOpts = application:get_env(?MODULE, dtls_options, []),
            {ok, _} = coap_server:start_dtls(coap_dtls_socket, DtlsPort, DtlsOpts);
        undefined ->
            ok
    end,
    {ok, Prefix} = application:get_env(?MODULE, prefix),
    coap_server_registry:add_handler(Prefix, rabbit_coap_handler, []),
    ok.

% end of file
