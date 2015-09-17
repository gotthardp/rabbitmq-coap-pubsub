%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

basic_test_() ->
    [?_assertEqual({ok, content, <<"</ps>;rt=\"core.ps\"">>}, coap_client:request(get, "coap://127.0.0.1/.well-known/core"))].

% end of file
