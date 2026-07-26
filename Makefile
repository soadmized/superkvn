.PHONY: check-env check-3xui up down logs nginx-http ssl-init ssl-renew cron-install cron-remove restart gen-pass 3xui-settings 3xui-create-inbound 3xui-inbound-exists 3xui-ensure-inbound 3xui-export-creds 3xui-init deploy

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
	@if ! command -v crontab >/dev/null 2>&1; then \
		echo "❌ Ошибка: crontab не установлен. Установите его (например, 'apt-get install cron') и попробуйте снова."; \
		exit 1; \
	fi
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' > /tmp/cron.tmp || true
	@echo "$(CRON_JOB)" >> /tmp/cron.tmp
	@crontab /tmp/cron.tmp
	@rm /tmp/cron.tmp
	@echo "✅ Cron-задача установлена"

cron-remove:
	@if ! command -v crontab >/dev/null 2>&1; then \
		echo "❌ Ошибка: crontab не установлен."; \
		exit 1; \
	fi
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' | crontab - || true

restart:
	$(MAKE) down
	$(MAKE) up

# Генерация пароля
gen-pass:
	@if [ ! -f "$(CREDS_FILE)" ]; then \
		PASS=$$(openssl rand -base64 18 | tr -d '\n'); \
		echo "admin:$$PASS" > $(CREDS_FILE); \
		chmod 600 $(CREDS_FILE); \
	else \
		echo "Пароль уже существует в $(CREDS_FILE)"; \
	fi

# Применение настроек (пароль, порт, путь)
3xui-settings: gen-pass check-3xui
	docker exec $(XUI_CONTAINER) apk add --no-cache jq curl
	docker exec $(XUI_CONTAINER) /app/x-ui setting \
		-username admin \
		-password "$$(cut -d: -f2 $(CREDS_FILE))" \
		-port $(UI_PORT) \
		-webBasePath /$(UI_DUMMY_PATH)/$(UI_PATH)/
	docker-compose restart $(XUI_CONTAINER)
	@sleep 5

# Вспомогательные переменные для API
COOKIE_FILE=/tmp/3xui_cookie.txt
CSRF_TOKEN_FILE=/tmp/3xui_csrf.txt
API_BASE=http://127.0.0.1:$(UI_PORT)$(shell [ "$(UI_DUMMY_PATH)" = "" ] && echo "/" || echo "/$(UI_DUMMY_PATH)/$(UI_PATH)/")

# Авторизация в API
3xui-login: check-3xui
	@echo "🔑 Авторизация в API 3x-ui..."
	@docker exec $(XUI_CONTAINER) apk add --no-cache curl jq > /dev/null 2>&1
	@# Получаем CSRF токен и начальную куку
	@docker exec $(XUI_CONTAINER) sh -c 'curl -s -c $(COOKIE_FILE) $(API_BASE) | sed -n "s/.*<meta name=\"csrf-token\" content=\"\([^\"]*\)\".*/\1/p" > $(CSRF_TOKEN_FILE)'
	@# Логинимся
	@docker exec $(XUI_CONTAINER) sh -c 'CSRF=$$(cat $(CSRF_TOKEN_FILE)); \
		curl -s -b $(COOKIE_FILE) -c $(COOKIE_FILE) -X POST $(API_BASE)login \
		-H "X-Csrf-Token: $$CSRF" \
		-H "Referer: $(API_BASE)" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$(shell cut -d: -f2 $(CREDS_FILE))" | grep -q "\"success\":true" || (echo "❌ Ошибка авторизации" && exit 1)'
	@echo "✅ Авторизация успешна"

# Создание инбаунда vless через API
3xui-create-inbound: 3xui-login
	@echo "🛠 Создание инбаунда через API..."
	@docker exec $(XUI_CONTAINER) sh -c 'CSRF=$$(cat $(CSRF_TOKEN_FILE)); \
		UUID=$$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed "s/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/"); \
		JSON=$$(printf "{\"enable\": true, \"remark\": \"$(INBOUND_REMARK)\", \"listen\": \"\", \"port\": $(NETWORK_PORT), \"protocol\": \"vless\", \"settings\": \"{\\\"clients\\\": [{\\\"id\\\": \\\"%s\\\", \\\"alterId\\\": 0, \\\"email\\\": \\\"user\\\", \\\"totalGB\\\": 0, \\\"expiryTime\\\": 0}], \\\"decryption\\\": \\\"none\\\", \\\"fallbacks\\\": []}\", \"streamSettings\": \"{\\\"network\\\": \\\"ws\\\", \\\"security\\\": \\\"none\\\", \\\"wsSettings\\\": {\\\"path\\\": \\\"/$(NETWORK_PATH)\\\", \\\"headers\\\": {}}}\", \"sniffing\": \"{\\\"enabled\\\": true, \\\"destOverride\\\": [\\\"http\\\", \\\"tls\\\"]}\", \"tag\": \"inbound-$(NETWORK_PORT)\"}" "$$UUID"); \
		curl -s -b $(COOKIE_FILE) -X POST $(API_BASE)panel/api/inbounds/add \
		-H "X-Csrf-Token: $$CSRF" \
		-H "Content-Type: application/json" \
		-d "$$JSON" | grep -q "\"success\":true" || (echo "❌ Ошибка создания инбаунда" && exit 1)'
	@echo "✅ Инбаунд создан"

# Проверка существования инбаунда через API
3xui-inbound-exists: 3xui-login
	@docker exec $(XUI_CONTAINER) sh -c 'curl -s -b $(COOKIE_FILE) $(API_BASE)panel/api/inbounds/list \
		| jq -e ".obj[] | select(.remark==\"$(INBOUND_REMARK)\" or .port==$(NETWORK_PORT))" > /dev/null'

# Создание инбаунда
3xui-ensure-inbound:
	@echo "🔍 Проверка inbound"
	@if $(MAKE) 3xui-inbound-exists; then \
		echo "Inbound уже существует"; \
	else \
		$(MAKE) 3xui-create-inbound; \
	fi

# Генерация ссылки подключения через API
3xui-export-creds: 3xui-login
	@echo "📦 Попытка генерации ссылки подключения"
	@UUID=$$(docker exec $(XUI_CONTAINER) sh -c 'curl -s -b $(COOKIE_FILE) $(API_BASE)panel/api/inbounds/list \
		| jq -r ".obj[] | select(.remark==\"$(INBOUND_REMARK)\" or .port==$(NETWORK_PORT)) | .settings" | jq -r ".clients[0].id"'); \
	if [ -z "$$UUID" ] || [ "$$UUID" = "null" ]; then \
		echo "❌ Не удалось найти инбаунд через API."; \
	else \
		echo "" >> $(CREDS_FILE); \
		echo "Connection link:" >> $(CREDS_FILE); \
		echo "vless://$$UUID@$(DOMAIN):443?type=ws&encryption=none&path=%2F$(NETWORK_PATH)&host=$(DOMAIN)&security=tls&sni=$(DOMAIN)&fp=chrome&alpn=h2%2Chttp%2F1.1" \
			>> $(CREDS_FILE); \
		echo "✅ Ссылка добавлена в $(CREDS_FILE)"; \
	fi

# Настройка 3x-ui
3xui-init: check-3xui
	$(MAKE) 3xui-settings
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
