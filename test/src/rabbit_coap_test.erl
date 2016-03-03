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
-include_lib("gen_coap/include/coap.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-import(coap_test, [text_resource/2]).

basic_test_() ->
    [?_assertMatch({ok,content,#coap_content{format= <<"application/link-format">>,
                                             payload= <<"</ps>;rt=\"core.ps\"">>}},
        coap_client:request(get, "coap://127.0.0.1/.well-known/core")),
    ?_assertEqual({error, not_found,#coap_content{}},
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/unknown", #coap_content{payload= <<"1">>})),
    ?_assertEqual({ok,created,#coap_content{}},
        coap_client:request(post, "coap://127.0.0.1/ps/%2f", #coap_content{payload= <<"<topic1>">>})),
    ?_assertEqual({ok,created,#coap_content{}},
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/topic1", #coap_content{payload= <<"1">>})),
    ?_assertEqual({ok,content,#coap_content{payload= <<"1">>}},
        coap_client:request(get, "coap://127.0.0.1/ps/%2f/topic1")),
    ?_assertEqual({ok,created,#coap_content{}},
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/topic1/key", #coap_content{format= <<"text/plain">>, payload= <<"2">>})),
    ?_assertEqual({ok,content,#coap_content{format= <<"text/plain">>, payload= <<"2">>}},
        coap_client:request(get, "coap://127.0.0.1/ps/%2f/topic1/key")),
    ?_assertMatch({ok,content,#coap_content{format= <<"application/link-format">>,
                                            payload= <<"</ps>;rt=\"core.ps\",</ps/%2F/topic1>,</ps/%2F/topic1/key>;ct=0">>}},
        coap_client:request(get, "coap://127.0.0.1/.well-known/core")),

    ?_assertEqual({{ok, pid, 0, content, #coap_content{payload= <<"1">>}},
            {coap_notify, pid, 1, {ok, content}, #coap_content{payload= <<"3">>}},
            {ok, content, #coap_content{payload= <<"3">>}}},
        coap_test:observe_and_modify("coap://127.0.0.1/ps/%2f/topic1", #coap_content{payload= <<"3">>})),
    ?_assertEqual({{ok, pid, 0, content, #coap_content{payload= <<"3">>}},
            {coap_notify, pid, 1, {ok, content}, text_resource(<<"4">>, 2000)},
            {ok, content, text_resource(<<"4">>, 2000)}},
        coap_test:observe_and_modify("coap://127.0.0.1/ps/%2f/topic1", text_resource(<<"4">>, 2000))),

    ?_assertEqual({ok,deleted,#coap_content{}},
        coap_client:request(delete, "coap://127.0.0.1/ps/%2f/topic1")),
    ?_assertMatch({ok,content,#coap_content{format= <<"application/link-format">>,
                                            payload= <<"</ps>;rt=\"core.ps\"">>}},
        coap_client:request(get, "coap://127.0.0.1/.well-known/core"))
    ].

% end of file
