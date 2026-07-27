.DEFAULT_GOAL := help
INV ?= inventories/lab
SHELL := /bin/bash

.PHONY: help lab-up lab-down lab-reset ping lint site verify cluster-id

help:  ## Bu yardım metnini göster
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

lab-up:  ## Lab container'larını ayağa kaldır
	./lab/lab-up.sh

lab-down:  ## Lab container'larını sil
	./lab/lab-down.sh

lab-reset: lab-down lab-up  ## Lab'ı sıfırdan kur

ping:  ## Tüm node'lara bağlantıyı doğrula
	ansible -i $(INV) all -m ping

lint:  ## yamllint + ansible-lint
	yamllint .
	ansible-lint

site:  ## Tüm bileşenleri kur
	ansible-playbook -i $(INV) playbooks/site.yml

verify:  ## Uçtan uca doğrulama
	ansible-playbook -i $(INV) playbooks/verify.yml

cluster-id:  ## Yeni bir KRaft cluster ID üret (bir kez, group_vars'a yazılır)
	@ansible -i $(INV) kafka_brokers[0] -m command \
		-a "/opt/kafka/bin/kafka-storage.sh random-uuid" 2>/dev/null | tail -1
