# SUPERKVN - (почти) неубиваемый kvn
[![GitHub Repo stars](https://img.shields.io/github/stars/soadmized/superkvn-landing?logo=github&style=flat-square)](https://github.com/soadmized/superkvn)
---
**SUPERKVN** - проект, который поднимает плохо детектируемое защищенное соединение с сервером через TLS и vless.

## 🚩 Предусловия  🚩
Перед развертываением проекта у вас уже должны быть:
- Сервер (`vps`/`dedicated`) с unix-подобной ОС, `docker` и `cron` (для автопродления SSL), расположенный за пределами РФ
- Зарегистрированный домен, указывающий на сервер (`A-запись`/`A-record`)
- Порты `80` и `443` открыты
---

## Структура проекта

```
superkvn/
├── site/ # html и статические файлы
│ └── index.html
├── nginx/ # конфиги nginx
│ └── main.conf.template   # шаблон основного конфига
| └── no_ssl.conf.template # шаблон конфига только с http
├── certbot/ # секретные файлы сертификатов
│ ├── conf/
│ └── www/
├── Dockerfile # для сборки nginx
├── docker-compose.yml
├── Makefile # команды для управления
└── README.md # описание проекта
```
---

## Особенности
SUPERKVN автоматически поднимает сайт, nginx, 3x-ui, получает SSL-сертификаты от Let’s Encrypt и создает инбаунд в 3x-ui.
SUPERKVN создает плохо детектируемое защищенное соединение с сервером: для провайдера это выглядит, как обычный HTTPS-трафик на ваш абсолютно нормальный, рабочий сайт с действующими сертификатами.
---

## Как использовать

### 1. Клонируем репозиторий
```bash
git clone https://github.com/soadmized/superkvn.git
cd superkvn
```

### 2. Поднимаем Nginx (HTTP)

```
make up-no-ssl
```
Сайт доступен по HTTP.

### 3. Получение SSL-сертификата (Let’s Encrypt) — ОДИН РАЗ
```
make ssl-init
```
⚠️ Перед запуском:
1. Домен должен указывать на сервер

2. Порты 80 и 443 должны быть открыты

Сертификаты сохраняются в `certbot/conf`.

### 4. Перезапуск Nginx с HTTPS
```
make restart
```
Сайт теперь доступен по HTTPS.

### 5. Логи
```
make logs
```
### 6. Обновление сертификатов
```
make ssl-renew
```
Можно добавить в cron для автоматического обновления:
```
make cron-install
```
### TODO
