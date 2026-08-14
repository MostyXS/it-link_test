.PHONY: deps deploy check

deps:
	ansible-galaxy collection install -r requirements.yml

deploy: deps
	ansible-playbook \
		-i inventory/hosts.yml \
		playbook.yml \
		--ask-vault-pass \
		-vv

check:
	./scripts/check.sh