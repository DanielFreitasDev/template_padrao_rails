#!/usr/bin/env bash

# ================================================================================
# Script para criar projetos Rails com o template padrão da empresa
#
# As modificações do projeto ficam em arquivos_template/template.rb (Rails
# application template), aplicado via `rails new -m`. Este script cuida do
# ambiente: mise/asdf, versão do Ruby, gem do Rails, git e mensagens.
# ================================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ================================================================================
# CONFIGURAÇÕES E CONSTANTES
# ================================================================================

readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_FILE="${SCRIPT_DIR}/arquivos_template.tar.gz"
readonly LOG_FILE="${SCRIPT_DIR}/rails_project_creator.log"

# Versões padrão (podem ser trocadas com --ruby e --rails)
DEFAULT_RUBY_VERSION="4.0.6"
DEFAULT_RAILS_VERSION="8.1.3"
DEFAULT_DATABASE="postgresql"

# Cores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Estado global (usado pelo trap de limpeza)
PROJECT_NAME=""
PROJECT_CREATED=0
TMP_EXTRACT_DIR=""

# Opções
RUBY_VERSION="$DEFAULT_RUBY_VERSION"
RAILS_VERSION="$DEFAULT_RAILS_VERSION"
DATABASE="$DEFAULT_DATABASE"
API_MODE=0
SKIP_BUNDLE=0
ASSUME_YES=0
ASSETS_PREFIX="__PADRAO__"   # __PADRAO__ = usar o nome do projeto

# Comando prefixo para rodar ruby/gem/rails na versão certa (ex.: mise exec ... --)
RUN_PREFIX=()

# ================================================================================
# FUNÇÕES DE UTILIDADE
# ================================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

print_message() { echo -e "${BLUE}[INFO]${NC} $1";    log_message "INFO: $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1";      log_message "SUCCESS: $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1";     log_message "WARNING: $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1" >&2;    log_message "ERROR: $1"; }
print_step()    { echo -e "\n${MAGENTA}═══${NC} ${BOLD}$1${NC} ${MAGENTA}═══${NC}"; log_message "STEP: $1"; }
print_debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $1"; log_message "DEBUG: $1"; }

confirm() {
    local message="${1:-Deseja continuar?}"
    local response

    if [[ "$ASSUME_YES" == "1" ]]; then
        return 0
    fi

    while true; do
        read -r -p "$(echo -e "${YELLOW}$message [s/N]:${NC} ")" response
        case "$response" in
            [sS][iI][mM]|[sS]) return 0 ;;
            [nN][aA][oO]|[nN]|"") return 1 ;;
            *) print_warning "Por favor, responda com 's' para sim ou 'n' para não." ;;
        esac
    done
}

usage() {
    cat << EOF
Uso: $(basename "$0") [NOME_DO_PROJETO] [opções]

Cria um projeto Rails já configurado com o template padrão da empresa
(Fomantic UI, Devise, Kaminari, Ransack, pt-BR, scaffold personalizado).

Opções:
  -d, --database BANCO   Banco de dados (padrão: $DEFAULT_DATABASE)
      --api              Cria em modo API (sem views/assets)
      --skip-bundle      Não roda bundle install (a parte JS fica pendente)
      --ruby VERSAO      Versão do Ruby   (padrão: $DEFAULT_RUBY_VERSION)
      --rails VERSAO     Versão do Rails  (padrão: $DEFAULT_RAILS_VERSION)
      --prefix VALOR     Prefixo dos assets p/ deploy em subcaminho
                         (padrão: nome do projeto; use "none" para desativar)
  -y, --yes              Não faz perguntas (assume sim / padrões)
      --debug            Mensagens de depuração
  -h, --help             Mostra esta ajuda

Exemplos:
  $(basename "$0")                        # modo interativo
  $(basename "$0") meuapp -y              # tudo padrão, sem perguntas
  $(basename "$0") meuapp --prefix none   # assets em /assets
EOF
}

# ================================================================================
# LIMPEZA EM CASO DE ERRO
# ================================================================================

cleanup_on_exit() {
    local exit_code=$?

    # Sempre remove a extração temporária do template
    if [[ -n "$TMP_EXTRACT_DIR" && -d "$TMP_EXTRACT_DIR" ]]; then
        rm -rf "$TMP_EXTRACT_DIR"
    fi

    if [[ $exit_code -ne 0 ]]; then
        print_error "Ocorreu um erro durante a execução (código: $exit_code)"

        if [[ "$PROJECT_CREATED" == "1" && -n "$PROJECT_NAME" && -d "$PROJECT_NAME" ]]; then
            if [[ "$ASSUME_YES" == "1" ]]; then
                print_warning "Projeto parcialmente criado mantido em: $PROJECT_NAME"
            elif confirm "Deseja remover o projeto parcialmente criado '$PROJECT_NAME'?"; then
                rm -rf "$PROJECT_NAME"
                print_success "Projeto parcialmente criado removido"
            fi
        fi
    fi
}
trap cleanup_on_exit EXIT

# ================================================================================
# VALIDAÇÕES
# ================================================================================

validate_project_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        print_error "Nome do projeto não pode estar vazio!"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        print_error "Nome do projeto deve começar com letra e conter apenas letras, números, underscore e hífen!"
        return 1
    fi

    if [[ -d "$name" ]]; then
        print_error "Diretório '$name' já existe!"
        return 1
    fi

    return 0
}

validate_template_file() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "Arquivo $(basename "$TEMPLATE_FILE") não encontrado em: $SCRIPT_DIR"
        return 1
    fi

    local listing
    if ! listing=$(tar -tzf "$TEMPLATE_FILE" 2>/dev/null); then
        print_error "Arquivo $(basename "$TEMPLATE_FILE") não é um tar.gz válido!"
        return 1
    fi

    if [[ "$listing" != *"arquivos_template/template.rb"* ]]; then
        print_error "O tarball não contém arquivos_template/template.rb (template antigo?)"
        return 1
    fi

    print_success "Arquivo de template válido"
    return 0
}

check_base_requirements() {
    print_step "Verificando requisitos do sistema"

    local missing=()
    for cmd in git tar; do
        if command -v "$cmd" > /dev/null 2>&1; then
            print_success "$cmd instalado"
        else
            missing+=("$cmd")
            print_error "Comando '$cmd' não encontrado"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Instale os comandos faltantes antes de continuar: ${missing[*]}"
        exit 1
    fi
}

# ================================================================================
# TOOLCHAIN (mise > asdf > sistema)
# ================================================================================

setup_toolchain() {
    print_step "Configurando Ruby $RUBY_VERSION"

    if command -v mise > /dev/null 2>&1; then
        print_success "mise encontrado: $(mise --version 2>/dev/null | head -n1)"

        if ! mise ls --installed ruby 2>/dev/null | grep -q "$RUBY_VERSION"; then
            print_message "Ruby $RUBY_VERSION não está instalado no mise."
            if confirm "Instalar Ruby $RUBY_VERSION via mise agora?"; then
                print_message "Instalando Ruby $RUBY_VERSION (pode demorar)..."
                mise install "ruby@$RUBY_VERSION"
            else
                print_error "Ruby $RUBY_VERSION é necessário para continuar."
                exit 1
            fi
        fi

        RUN_PREFIX=(mise exec "ruby@$RUBY_VERSION" --)
        print_success "Usando Ruby via mise: $("${RUN_PREFIX[@]}" ruby -v)"
        return 0
    fi

    if command -v asdf > /dev/null 2>&1; then
        print_success "asdf encontrado (o arquivo .tool-versions do projeto apontará para o Ruby $RUBY_VERSION)"
        if ! asdf list ruby 2>/dev/null | tr -d ' *' | grep -qx "$RUBY_VERSION"; then
            print_warning "Ruby $RUBY_VERSION não está instalado no asdf."
            print_message "Instale com: asdf install ruby $RUBY_VERSION"
            confirm "Continuar usando o Ruby atual do sistema?" || exit 1
        fi
    fi

    # Sem gerenciador (ou asdf com shims ativos): usa o ruby do PATH
    if ! command -v ruby > /dev/null 2>&1; then
        print_error "Nenhum Ruby encontrado. Instale o mise (https://mise.jdx.dev) e rode novamente."
        exit 1
    fi

    local current_version
    current_version=$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)
    if [[ "$current_version" != "$RUBY_VERSION" ]]; then
        print_warning "Ruby ativo é $current_version, esperado $RUBY_VERSION"
        confirm "Deseja continuar mesmo assim?" || exit 1
        RUBY_VERSION="$current_version"
    fi
    print_success "Usando Ruby do sistema: $(ruby -v)"
}

ensure_rails_gem() {
    print_step "Verificando Rails $RAILS_VERSION"

    if "${RUN_PREFIX[@]}" gem list -i -e rails -v "$RAILS_VERSION" > /dev/null 2>&1; then
        print_success "Gem rails $RAILS_VERSION já instalada"
        return 0
    fi

    print_message "Gem rails $RAILS_VERSION não encontrada neste Ruby."
    if confirm "Instalar rails $RAILS_VERSION agora?"; then
        "${RUN_PREFIX[@]}" gem install rails -v "$RAILS_VERSION" --no-document
        print_success "Rails $RAILS_VERSION instalado"
    else
        print_error "Rails $RAILS_VERSION é necessário para continuar."
        exit 1
    fi
}

# ================================================================================
# CRIAÇÃO DO PROJETO
# ================================================================================

extract_template() {
    print_step "Preparando arquivos de template"

    TMP_EXTRACT_DIR=$(mktemp -d -t rails_template.XXXXXX)
    tar -xzf "$TEMPLATE_FILE" -C "$TMP_EXTRACT_DIR"

    if [[ ! -f "$TMP_EXTRACT_DIR/arquivos_template/template.rb" ]]; then
        print_error "template.rb não encontrado após extração!"
        exit 1
    fi
    print_success "Template extraído em diretório temporário"
}

create_rails_project() {
    print_step "Criando projeto Rails: $PROJECT_NAME"

    local prefix="$ASSETS_PREFIX"
    if [[ "$prefix" == "__PADRAO__" ]]; then
        prefix="$PROJECT_NAME"
    elif [[ "$prefix" == "none" ]]; then
        prefix=""
    fi

    local cmd=("${RUN_PREFIX[@]}" rails "_${RAILS_VERSION}_" new "$PROJECT_NAME"
               "--database=$DATABASE"
               -m "$TMP_EXTRACT_DIR/arquivos_template/template.rb")
    [[ "$API_MODE" == "1" ]] && cmd+=(--api)
    [[ "$SKIP_BUNDLE" == "1" ]] && cmd+=(--skip-bundle)

    print_message "Executando: rails _${RAILS_VERSION}_ new $PROJECT_NAME --database=$DATABASE -m template.rb"
    PROJECT_CREATED=1

    RPC_TEMPLATE_DIR="$TMP_EXTRACT_DIR/arquivos_template" \
    RPC_ASSETS_PREFIX="$prefix" \
        "${cmd[@]}"

    print_success "Projeto Rails criado com sucesso!"
}

finalize_project() {
    print_step "Finalizando configuração"

    cd "$PROJECT_NAME"

    # Versão do Ruby para mise e asdf (o .ruby-version já é criado pelo Rails)
    echo "ruby $RUBY_VERSION" > .tool-versions
    print_success ".tool-versions criado (ruby $RUBY_VERSION)"

    if [[ ! -d .git ]]; then
        git init > /dev/null
        print_success "Repositório Git inicializado"
    fi

    if git config user.email > /dev/null 2>&1 && [[ -n "$(git config user.email)" ]]; then
        git add .
        if git commit -q -m "feat: projeto inicial com template padrão v${SCRIPT_VERSION} (Rails ${RAILS_VERSION} / Ruby ${RUBY_VERSION})"; then
            print_success "Commit inicial realizado"
        else
            print_warning "Nada para commitar"
        fi
    else
        print_warning "git user.name/user.email não configurados; commit inicial não foi feito."
        print_message "Configure com: git config --global user.name \"Seu Nome\" && git config --global user.email voce@empresa.gov.br"
    fi

    cd ..
}

# ================================================================================
# ARGUMENTOS
# ================================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--database)  DATABASE="${2:?--database requer um valor}"; shift 2 ;;
            --api)          API_MODE=1; shift ;;
            --skip-bundle)  SKIP_BUNDLE=1; shift ;;
            --ruby)         RUBY_VERSION="${2:?--ruby requer um valor}"; shift 2 ;;
            --rails)        RAILS_VERSION="${2:?--rails requer um valor}"; shift 2 ;;
            --prefix)       ASSETS_PREFIX="${2:?--prefix requer um valor}"; shift 2 ;;
            -y|--yes)       ASSUME_YES=1; shift ;;
            --debug)        DEBUG=1; shift ;;
            -h|--help)      usage; trap - EXIT; exit 0 ;;
            -*)             print_error "Opção desconhecida: $1"; usage; exit 1 ;;
            *)
                if [[ -n "$PROJECT_NAME" ]]; then
                    print_error "Apenas um nome de projeto pode ser informado."
                    exit 1
                fi
                PROJECT_NAME="$1"; shift ;;
        esac
    done
}

# ================================================================================
# FUNÇÃO PRINCIPAL
# ================================================================================

main() {
    parse_args "$@"

    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   Rails Project Creator v${SCRIPT_VERSION}                            ║"
    echo "║   Ruby ${RUBY_VERSION} · Rails ${RAILS_VERSION} · Fomantic UI              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_message "=== Iniciando script v$SCRIPT_VERSION ==="

    check_base_requirements
    validate_template_file || exit 1

    # Nome do projeto (interativo se não veio por argumento)
    if [[ -z "$PROJECT_NAME" ]]; then
        if [[ "$ASSUME_YES" == "1" ]]; then
            print_error "Com --yes é obrigatório informar o nome do projeto."
            exit 1
        fi
        while true; do
            read -r -p "$(echo -e "${BOLD}Digite o nome do projeto:${NC} ")" PROJECT_NAME
            validate_project_name "$PROJECT_NAME" && break
        done
    else
        validate_project_name "$PROJECT_NAME" || exit 1
    fi

    # Opções adicionais (apenas no modo interativo e sem flags explícitas)
    if [[ "$ASSUME_YES" != "1" && "$API_MODE" == "0" && "$SKIP_BUNDLE" == "0" ]]; then
        if confirm "Deseja configurar opções adicionais para o projeto?"; then
            confirm "Modo API apenas (--api)?" && API_MODE=1
            confirm "Pular bundle install inicial (--skip-bundle)?" && SKIP_BUNDLE=1
        fi
    fi

    setup_toolchain
    ensure_rails_gem
    extract_template
    create_rails_project
    finalize_project

    echo -e "\n${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          🎉 PROJETO CRIADO COM SUCESSO! 🎉                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    print_success "Projeto '$PROJECT_NAME' criado e configurado!"

    echo -e "\n${BOLD}Próximos passos:${NC}"
    echo -e "  ${CYAN}cd $PROJECT_NAME${NC}"
    [[ "$SKIP_BUNDLE" == "1" ]] && echo -e "  ${CYAN}bundle install && bin/rails importmap:install turbo:install stimulus:install${NC}"
    echo -e "  ${CYAN}bin/rails db:prepare${NC}"
    echo -e "  ${CYAN}bin/rails server${NC}"

    echo -e "\n${BOLD}Recursos incluídos:${NC}"
    if [[ "$API_MODE" == "1" ]]; then
        echo "  ✓ Modo API (sem views/assets)"
    else
        echo "  ✓ Fomantic UI 2.9.4 + jQuery 3.7.1 (vendorizados)"
        echo "  ✓ Scaffold personalizado (lib/templates)"
        echo "  ✓ Breadcrumbs, paginação e busca com sessão por controller"
    fi
    echo "  ✓ Devise (autenticação) · Kaminari (paginação) · Ransack (busca)"
    echo "  ✓ Localização pt-BR e fuso America/Fortaleza"
    echo "  ✓ Veja o README.md do projeto para as pendências iniciais"

    log_message "=== Script finalizado com sucesso ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
