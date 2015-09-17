RELEASABLE:=true
RETAIN_ORIGINAL_VERSION:=true
DEPS:=rabbitmq-server rabbitmq-lvc-plugin rabbitmq-erlang-client rabbitmq-gen-coap

WITH_BROKER_TEST_COMMANDS:=eunit:test(rabbit_coap_test,[verbose,{report,{eunit_surefire,[{dir,\"test\"}]}}])
WITH_BROKER_SETUP_SCRIPTS:=$(PACKAGE_DIR)/test/setup-rabbit-test.sh
