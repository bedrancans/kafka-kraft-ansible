.DEFAULT_GOAL := help
INV ?= inventories/lab
SHELL := /bin/bash

.PHONY: help lab-up lab-down lab-reset ping lint site verify cluster-id

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

lab-up:  ## Bring up the lab containers
	./lab/lab-up.sh

lab-down:  ## Tear down the lab containers
	./lab/lab-down.sh

lab-reset: lab-down lab-up  ## Rebuild the lab from scratch

ping:  ## Verify connectivity to every node
	ansible -i $(INV) all -m ping

lint:  ## Run yamllint + ansible-lint
	yamllint .
	ansible-lint

site:  ## Deploy every component
	ansible-playbook -i $(INV) playbooks/site.yml

verify:  ## Run the end-to-end verification
	ansible-playbook -i $(INV) playbooks/verify.yml

cluster-id:  ## Generate a KRaft cluster ID (once; store it in group_vars)
	@ansible -i $(INV) kafka_brokers[0] -m command \
		-a "/opt/kafka/bin/kafka-storage.sh random-uuid" 2>/dev/null | tail -1
