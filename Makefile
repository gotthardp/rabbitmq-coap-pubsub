PROJECT = rabbitmq_coap_pubsub

DEPS = amqp_client rabbitmq_lvc gen_coap

TEST_DEPS = rabbitmq_test

DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

PACKAGES += gen_coap
pkg_gen_coap_name = gen_coap
pkg_gen_coap_description = Generic Erlang CoAP Client/Server
pkg_gen_coap_homepage = https://github.com/gotthardp/gen_coap
pkg_gen_coap_fetch = git
pkg_gen_coap_repo = https://github.com/gotthardp/gen_coap.git
pkg_gen_coap_commit = v0.1.0

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk

# --------------------------------------------------------------------
# Testing.
# --------------------------------------------------------------------

WITH_BROKER_SETUP_SCRIPTS := $(CURDIR)/test/setup-rabbit-test.sh
WITH_BROKER_TEST_COMMANDS := \
        eunit:test(rabbit_coap_test,[verbose,{report,{eunit_surefire,[{dir,\"test\"}]}}])

# end of file
