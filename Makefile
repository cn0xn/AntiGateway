PI_HOST ?= user@192.168.1.5
REPO    := github.com/cn0xn/AntiGateway

.PHONY: push deploy push-deploy logs status

## Запушить изменения на GitHub
push:
	git push

## Задеплоить на Pi (без push)
deploy:
	ssh $(PI_HOST) 'cd /opt/antigateway && sudo bash deploy.sh'

## Push + deploy одной командой
push-deploy:
	git push
	ssh $(PI_HOST) 'cd /opt/antigateway && sudo bash deploy.sh'

## Посмотреть логи web UI на Pi
logs:
	ssh $(PI_HOST) 'journalctl -u antigateway-ui -f'

## Статус сервисов на Pi
status:
	ssh $(PI_HOST) 'systemctl status antigateway-ui awg-quick@awg0 dnsmasq zapret2-nfqws2 nftables --no-pager'

## Открыть SSH на Pi
ssh:
	ssh $(PI_HOST)
