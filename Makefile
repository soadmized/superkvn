.PHONY: check-env check-3xui up down logs nginx-http ssl-init ssl-renew cron-install cron-remove restart gen-pass 3xui-change-password 3xui-create-inbound 3xui-inbound-exists 3xui-ensure-inbound 3xui-export-creds 3xui-init deploy

include .env
export

.NOTPARALLEL:

XUI_PASS_FILE=$(HOME)/creds.txt
CREDS_FILE=$(HOME)/creds.txt
XUI_CONTAINER=xray
INBOUND_REMARK=$(DOMAIN)-$(NETWORK_PORT)
CRON_CMD=cd $(PWD) && $(MAKE) ssl-renew >> /var/log/ssl-renew.log 2>&1
CRON_JOB=0 3 * * * $(CRON_CMD)

check-env:
	@if [ -z "$(DOMAIN)" ]; then \
		echo "DOMAIN не задан в .env"; exit 1; \
	fi
	@if [ -z "$(EMAIL)" ]; then \
		echo "EMAIL не задан в .env"; exit 1; \
	fi

check-3xui:
	@docker ps | grep -q xray || (echo "xray container not running" && exit 1)

up: check-env
	envsubst '$$DOMAIN $$UI_DUMMY_PATH $$UI_PATH $$UI_PORT $$NETWORK_PATH $$NETWORK_PORT' \
		< nginx/main.conf.template > nginx/default.conf
	docker-compose up -d --build --force-recreate

down:
	docker-compose down

logs:
	docker-compose logs -f nginx

nginx-http: check-env
	envsubst '$$DOMAIN $$UI_DUMMY_PATH $$UI_PATH $$UI_PORT $$NETWORK_PATH $$NETWORK_PORT' \
		< nginx/no_ssl.conf.template > nginx/default.conf
	docker-compose up -d --force-recreate --build nginx

ssl-init: check-env
	@echo "🔐 Выпуск SSL-сертификата для $(DOMAIN)"
	docker-compose run --rm certbot certonly \
		--webroot \
		--webroot-path=/var/www/certbot \
		--email $(EMAIL) \
		--agree-tos \
		--no-eff-email \
		-d $(DOMAIN) -d www.$(DOMAIN)

ssl-renew:
	@echo "♻️ Обновление SSL-сертификатов"
	docker-compose run --rm certbot renew
	docker-compose restart nginx

cron-install:
	@echo "⏱ Установка cron-задачи для SSL"
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' > /tmp/cron.tmp || true
	@echo "$(CRON_JOB)" >> /tmp/cron.tmp
	@crontab /tmp/cron.tmp
	@rm /tmp/cron.tmp
	@echo "✅ Cron-задача установлена"

cron-remove:
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' | crontab - || true

restart:
	$(MAKE) down
	$(MAKE) up

# Генерация пароля
gen-pass:
	@if [ ! -f "$(CREDS_FILE)" ]; then \
		PASS=$$(openssl rand -base64 24 | tr -d '\n'); \
		echo "admin:$$PASS" > $(CREDS_FILE); \
		chmod 600 $(CREDS_FILE); \
	else \
		echo "Пароль уже существует в $(CREDS_FILE)"; \
	fi

# Применение пароля
3xui-change-password: gen-pass check-3xui
	docker exec $(XUI_CONTAINER) x-ui setting \
		-username admin \
		-password "$$(cut -d: -f2 $(CREDS_FILE))"

# Создание инбаунда vless без tls
3xui-create-inbound: check-3xui
	docker exec $(XUI_CONTAINER) x-ui inbound add \
		--protocol vless \
		--port $(NETWORK_PORT) \
		--remark "$(INBOUND_REMARK)" \
		--transport ws \
		--path /$(NETWORK_PATH) \
		--enable

# Проверка существования инбаунда
3xui-inbound-exists:
	@docker exec $(XUI_CONTAINER) x-ui inbound list --json \
		| jq -e '.[] | select(.remark=="$(INBOUND_REMARK)")' > /dev/null 2>&1 || exit 1

# Создание инбаунда
3xui-ensure-inbound:
	@echo "🔍 Проверка inbound"
	@if $(MAKE) 3xui-inbound-exists; then \
		echo "Inbound уже существует"; \
	else \
		$(MAKE) 3xui-create-inbound; \
	fi

# Генерация ссылки подключения
3xui-export-creds: check-3xui
	@echo "📦 Генерация ссылки подключения"
	@UUID=$$(docker exec $(XUI_CONTAINER) x-ui inbound list --json \
		| jq -r '.[] | select(.remark=="$(INBOUND_REMARK)") | .clients[0].id'); \
	echo "" >> $(CREDS_FILE); \
	echo "Connection link:" >> $(CREDS_FILE); \
	echo "vless://$$UUID@$(DOMAIN):443?type=ws&encryption=none&path=%2F$(NETWORK_PATH)&host=$(DOMAIN)&security=tls&sni=$(DOMAIN)&fp=chrome&alpn=h2%2Chttp%2F1.1" \
		>> $(CREDS_FILE); \
	echo "✅ Ссылка добавлена в $(CREDS_FILE)"

# Настройка 3x-ui
3xui-init: check-3xui
	$(MAKE) 3xui-change-password
	$(MAKE) 3xui-ensure-inbound
	$(MAKE) 3xui-export-creds

# Поднятие всего и сразу
deploy:
	$(MAKE) nginx-http
	$(MAKE) ssl-init
	$(MAKE) cron-install
	$(MAKE) restart
	$(MAKE) 3xui-init
	@echo "Деплой завершён! Ссылка подключения и креды для админки в $(CREDS_FILE)"
