## How to launch

## Deploy

```bash
make deploy
```

## Check

```bash
make check

# Конфигурация была проверена в контексте двух VM yandex-cloud и локальной машины.

----------------------------------

## Prerequisites

- 2 x Ubuntu Server 24.04 LTS
- bootstrap SSH access to both hosts
- Ansible on the controller
- Vault password

## Bootstrap SSH key

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/system-admin-test \
  -C "system-admin-test"
```

Install `~/.ssh/system-admin-test.pub` for the bootstrap user on both servers.

## Configure

Set target addresses in:

```text
inventory/hosts.yml
```

Set non-secret infrastructure parameters in:

```text
group_vars/all.yml
```

Create the encrypted secret file:

```bash
ansible-vault create group_vars/vault.yml
```

It must contain:

```yaml
vault_postgres_password: change_me
```

#Mistakes Occured:
- Nginx Configuration
- Cloud Ports Exposure(Security-Related)
- Wrong Variables Specified
