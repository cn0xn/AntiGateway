PI_HOST ?= user@192.168.1.5
REPO    := github.com/cn0xn/AntiGateway

.PHONY: push deploy push-deploy logs status ssh

## Запушить изменения на GitHub
push:
	git push

## Задеплоить на Pi через rsync (без push)
deploy:
	rsync -az --rsync-path="sudo rsync" --exclude='.git' --exclude='SESSION.md' \
	    ./ $(PI_HOST):/opt/antigateway/
	ssh $(PI_HOST) 'sudo bash /opt/antigateway/deploy.sh'

## Push на GitHub + деплой на Pi одной командой
push-deploy:
	git push
	rsync -az --rsync-path="sudo rsync" --exclude='.git' --exclude='SESSION.md' \
	    ./ $(PI_HOST):/opt/antigateway/
	ssh $(PI_HOST) 'sudo bash /opt/antigateway/deploy.sh'

## Посмотреть логи web UI на Pi
logs:
	ssh $(PI_HOST) 'journalctl -u antigateway-ui -f'

## Статус сервисов на Pi
status:
	ssh $(PI_HOST) 'systemctl status antigateway-ui awg-quick@awg0 dnsmasq zapret2-nfqws2 nftables --no-pager'

## Открыть SSH на Pi
ssh:
	ssh $(PI_HOST)
