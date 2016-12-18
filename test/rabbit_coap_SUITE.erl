%
% The contents of this file are subject to the Mozilla Public License
% Version 1.1 (the "License"); you may not use this file except in
% compliance with the License. You may obtain a copy of the License at
% http://www.mozilla.org/MPL/
%
% Copyright (c) 2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(rabbit_coap_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("gen_coap/include/coap.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-import(coap_test, [text_resource/2]).

-compile(export_all).

% Testsuite setup/teardown

all() -> [
    main_test
].

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    Config1 = rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE}
    ]),
    rabbit_ct_helpers:run_setup_steps(Config1,
        rabbit_ct_broker_helpers:setup_steps() ++ rabbit_ct_client_helpers:setup_steps()).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
        rabbit_ct_client_helpers:teardown_steps() ++ rabbit_ct_broker_helpers:teardown_steps()).

init_per_group(_, Config) -> Config.
end_per_group(_, Config) -> Config.

init_per_testcase(Testcase, Config) ->
    rabbit_ct_broker_helpers:add_user(Config, <<"anonymous">>),
    rabbit_ct_broker_helpers:set_full_permissions(Config, <<"anonymous">>, <<"/">>),
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_broker_helpers:delete_user(Config, <<"anonymous">>),
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

% Testcases

main_test(_Config) ->
    {ok,content,#coap_content{format= <<"application/link-format">>,
                              payload= <<"</ps>;rt=\"core.ps\"">>}} =
        coap_client:request(get, "coap://127.0.0.1/.well-known/core"),
    {error, not_found,#coap_content{payload= <<"NOT_FOUND - no exchange 'unknown' in vhost '/'">>}} =
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/unknown", #coap_content{payload= <<"1">>}),
    {ok,created,#coap_content{}} =
        coap_client:request(post, "coap://127.0.0.1/ps/%2f", #coap_content{payload= <<"<topic1>">>}),
    {ok,created,#coap_content{}} =
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/topic1", #coap_content{payload= <<"1">>}),
    {ok,content,#coap_content{payload= <<"1">>}} =
        coap_client:request(get, "coap://127.0.0.1/ps/%2f/topic1"),
    {ok,created,#coap_content{}} =
        coap_client:request(put, "coap://127.0.0.1/ps/%2f/topic1/key", #coap_content{format= <<"text/plain">>, payload= <<"2">>}),
    {ok,content,#coap_content{format= <<"text/plain">>, payload= <<"2">>}} =
        coap_client:request(get, "coap://127.0.0.1/ps/%2f/topic1/key"),
    {ok,content,#coap_content{format= <<"application/link-format">>,
                              payload= <<"</ps>;rt=\"core.ps\",</ps/%2F/topic1>,</ps/%2F/topic1/key>;ct=0">>}} =
        coap_client:request(get, "coap://127.0.0.1/.well-known/core"),

    {{ok, pid, 0, content, #coap_content{payload= <<"1">>}},
            {coap_notify, pid, 1, {ok, content}, #coap_content{payload= <<"3">>}},
            {ok, content, #coap_content{payload= <<"3">>}}} =
        coap_test:observe_and_modify("coap://127.0.0.1/ps/%2f/topic1", #coap_content{payload= <<"3">>}),

    Text4 = text_resource(<<"4">>, 2000),
    {{ok, pid, 0, content, #coap_content{payload= <<"3">>}},
            {coap_notify, pid, 1, {ok, content}, Text4},
            {ok, content, Text4}} =
        coap_test:observe_and_modify("coap://127.0.0.1/ps/%2f/topic1", text_resource(<<"4">>, 2000)),

    {ok,deleted,#coap_content{}} =
        coap_client:request(delete, "coap://127.0.0.1/ps/%2f/topic1"),
    {ok,content,#coap_content{format= <<"application/link-format">>,
                                            payload= <<"</ps>;rt=\"core.ps\"">>}} =
        coap_client:request(get, "coap://127.0.0.1/.well-known/core").

% end of file
