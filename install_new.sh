#!/usr/bin/env bash
set -e

# ==============================
# Настройки твоего репозитория
# ==============================

# !!! ЗАМЕНИ на свой репозиторий !!!
REPO_RAW_DEFAULT="https://raw.githubusercontent.com/elenrabota96-dot/mtproto-installer/refs/heads/main"

REPO_RAW="${REPO_RAW:-$REPO_RAW_DEFAULT}"

# куда ставим
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"

# дефолтный фейковый домен
FAKE_DOMAIN="${FAKE_DOMAIN:-vk.ru}"

# внутренний порт telemt (обычно менять не надо)
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"

# внешний порт, который будет слушать VPS
LISTEN_PORT="${LISTEN_PORT:-8444}"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

fetch() {
	local url="$1"
	local dest="$2"
	if ! curl -fsSL "$url" -o "$dest"; then
		err "Не удалось загрузить: $url"
	fi
}

rerun_cmd() {
	if [[ "$0" == *bash* ]] || [[ "$0" == -* ]]; then
		echo "curl -sSL ${REPO_RAW}/install.sh | bash"
	else
		local dir
		dir="$(cd "$(dirname "$0")" && pwd)"
		echo "bash ${dir}/$(basename "$0")"
	fi
}

check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			info "Docker доступен."
			return 0
		fi
		echo ""
		warn "Docker установлен, но текущий пользователь не в группе docker."
		echo ""
		echo "Выполните команду:"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi

	info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh

	if ! docker info &>/dev/null 2>&1; then
		echo ""
		warn "Docker установлен. Нужно добавить пользователя в группу docker."
		echo ""
		echo "Выполните команду:"
		echo -e "  ${GREEN}sudo usermod -aG docker \$USER && newgrp docker${NC}"
		echo ""
		echo "Затем запустите этот скрипт снова:"
		echo -e "  ${GREEN}$(rerun_cmd)${NC}"
		echo ""
		exit 1
	fi
}

is_port_in_use() {
	local port="$1"
	if command -v ss &>/dev/null; then
		ss -tuln 2>/dev/null | grep -qE "[.:]${port}[[:space:]]"
		return $?
	fi
	if command -v nc &>/dev/null; then
		nc -z 127.0.0.1 "$port" 2>/dev/null
		return $?
	fi
	return 1
}

check_port_or_exit() {
	if is_port_in_use "$LISTEN_PORT"; then
		err "Порт ${LISTEN_PORT} уже занят. Укажи другой через переменную окружения: LISTEN_PORT=XXXX"
	fi
}

generate_secret() {
	openssl rand -hex 16
}

download_and_configure() {
	info "Загрузка файлов из ${REPO_RAW} ..."
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	fetch "${REPO_RAW}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
	fetch "${REPO_RAW}/traefik/dynamic/tcp.yml" "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	fetch "${REPO_RAW}/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"

	# Подстановка порта в docker-compose
	sed "s/443:443/${LISTEN_PORT}:443/" "${INSTALL_DIR}/docker-compose.yml" \
		> "${INSTALL_DIR}/docker-compose.yml.tmp" \
		&& mv "${INSTALL_DIR}/docker-compose.yml.tmp" "${INSTALL_DIR}/docker-compose.yml"

	SECRET=$(generate_secret)

	# Генерация telemt.toml
	sed -e "s/ПОДСТАВЬТЕ_32_СИМВОЛА_HEX/${SECRET}/g" \
	    -e "s/tls_domain = \"1c.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
	    "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"

	rm -f "${INSTALL_DIR}/telemt.toml.example"
	info "Создан ${INSTALL_DIR}/telemt.toml (домен маскировки: ${FAKE_DOMAIN})"

	# Настройка Traefik tcp.yml
	local tcp_yml="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	sed -e "s/1c\.ru/${FAKE_DOMAIN}/g" \
	    -e "s/telemt:1234/telemt:${TELEMT_INTERNAL_PORT}/g" \
	    "$tcp_yml" > "${tcp_yml}.tmp" && mv "${tcp_yml}.tmp" "$tcp_yml"

	info "Настроен Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT}"

	printf '%s' "$SECRET" > "${INSTALL_DIR}/.secret"
}

run_compose() {
	cd "${INSTALL_DIR}"
	docker compose pull -q 2>/dev/null || true
	docker compose up -d
	info "Контейнеры запущены."
}

print_link() {
	local SECRET TLS_DOMAIN DOMAIN_HEX LONG_SECRET SERVER_IP LINK

	SECRET=$(cat "${INSTALL_DIR}/.secret" 2>/dev/null | tr -d '\n\r')
	[[ -z "$SECRET" ]] && err "Секрет не найден в ${INSTALL_DIR}/.secret"

	TLS_DOMAIN=$(grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "${INSTALL_DIR}/telemt.toml" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')

	[[ -z "$TLS_DOMAIN" ]] && err "tls_domain не найден в ${INSTALL_DIR}/telemt.toml"

	DOMAIN_HEX=$(printf '%s' "$TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')

	if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
		LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"
	else
		LONG_SECRET="$SECRET"
	fi

	SERVER_IP=""
	for url in https://ifconfig.me/ip https://icanhazip.com https://api.ipify.org https://checkip.amazonaws.com; do
		raw=$(curl -s --connect-timeout 3 "$url" 2>/dev/null | tr -d '\n\r')
		if [[ -n "$raw" ]] && [[ ! "$raw" =~ [[:space:]] ]] && [[ ! "$raw" =~ (error|timeout|upstream|reset|refused) ]] && [[ "$raw" =~ ^([0-9.]+|[0-9a-fA-F:]+)$ ]]; then
			SERVER_IP="$raw"
			break
		fi
	done

	if [[ -z "$SERVER_IP" ]]; then
		SERVER_IP="YOUR_SERVER_IP"
		warn "Не удалось определить внешний IP. Подставь IP сервера вручную."
	fi

	LINK="tg://proxy?server=${SERVER_IP}&port=${LISTEN_PORT}&secret=${LONG_SECRET}"

	echo ""
	echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║  Telegram MTProto Proxy (FakeTLS)                       ║${NC}"
	echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
	echo ""
	echo -e "  ${GREEN}${LINK}${NC}"
	echo ""
	echo "  Порт:           ${LISTEN_PORT}"
	echo "  Fake TLS домен: ${FAKE_DOMAIN}"
	echo "  Каталог:        ${INSTALL_DIR}"
	echo ""
	echo "  Логи:      cd ${INSTALL_DIR} && docker compose logs -f"
	echo "  Остановка: cd ${INSTALL_DIR} && docker compose down"
	echo ""
	echo "  Не публикуй ссылку публично."
	echo ""
}

main() {
	[[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"

	check_docker
	check_port_or_exit
	download_and_configure
	run_compose
	print_link
}

main "$@"
