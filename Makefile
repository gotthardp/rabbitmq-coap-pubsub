PROJECT = rabbitmq_coap_pubsub
PROJECT_DESCRIPTION = CoAP Publish-Subscribe interface to RabbitMQ

DEPS = rabbit_common rabbit amqp_client rabbitmq_lvc gen_coap
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers

DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

NO_AUTOPATCH += gen_coap

PACKAGES += gen_coap
pkg_gen_coap_name = gen_coap
pkg_gen_coap_fetch = git
pkg_gen_coap_repo = https://github.com/gotthardp/gen_coap.git
pkg_gen_coap_commit = 9301fec23acababb3c6bde79c95cc67f4658850a

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk

# end of file
