#!/bin/bash

# ================================================================================
# Script para criar projetos Rails com template personalizado
# Versão: Rails 8.0.3 / Ruby 3.4.6
# ================================================================================

set -euo pipefail  # Para o script em caso de erro, variável não definida ou falha em pipe
IFS=$'\n\t'        # Define separadores internos de campo

# ================================================================================
# CONFIGURAÇÕES E CONSTANTES
# ================================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_FILE="arquivos_template.tar.gz"
readonly BACKUP_SUFFIX=".bak"
readonly LOG_FILE="${SCRIPT_DIR}/rails_project_creator.log"

# Cores para output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Configurações padrões
DEFAULT_DATABASE="postgresql"
DEFAULT_LIMIT_VALUES=(5 10 15 20 25)
DEFAULT_RUBY_VERSION="3.4.7"
DEFAULT_RAILS_VERSION="8.1.0"

# ================================================================================
# FUNÇÕES DE UTILIDADE
# ================================================================================

# Função para logging
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# Funções para imprimir mensagens coloridas
print_message() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log_message "INFO: $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    log_message "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
    log_message "WARNING: $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
    log_message "ERROR: $1"
}

print_step() {
    echo -e "\n${MAGENTA}═══${NC} $1 ${MAGENTA}═══${NC}"
    log_message "STEP: $1"
}

print_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
        log_message "DEBUG: $1"
    fi
}

# Função para exibir spinner durante operações longas
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⣾⣽⣻⢿⡿⣟⣯⣷'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Função para confirmar ação
confirm() {
    local message="${1:-Deseja continuar?}"
    local response

    while true; do
        read -p "$(echo -e "${YELLOW}$message [s/N]:${NC} ")" response
        case "$response" in
            [sS][iI][mM]|[sS])
                return 0
                ;;
            [nN][aA][oO]|[nN]|"")
                return 1
                ;;
            *)
                print_warning "Por favor, responda com 's' para sim ou 'n' para não."
                ;;
        esac
    done
}

# Função para verificar comandos necessários
check_requirements() {
    print_step "Verificando requisitos do sistema"

    local missing_requirements=()
    local commands=("rails" "git" "tar" "sed" "ruby" "bundle")

    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_requirements+=("$cmd")
            print_error "Comando '$cmd' não encontrado"
        else
            local version=$($cmd --version 2>/dev/null | head -n1 || echo "versão não disponível")
            print_success "$cmd instalado: $version"
        fi
    done

    if [ ${#missing_requirements[@]} -gt 0 ]; then
        print_error "Requisitos faltando: ${missing_requirements[*]}"
        print_message "Por favor, instale os comandos faltantes antes de continuar."
        exit 1
    fi

    # Verificar versões específicas se necessário
    if command -v ruby &> /dev/null; then
        local ruby_version=$(ruby -v | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        if [[ "$ruby_version" != "$DEFAULT_RUBY_VERSION" ]]; then
            print_warning "Versão do Ruby é $ruby_version, esperado $DEFAULT_RUBY_VERSION"
            if ! confirm "Deseja continuar mesmo assim?"; then
                exit 1
            fi
        fi
    fi
}

# Função para limpar em caso de erro
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Ocorreu um erro durante a execução (código: $exit_code)"

        # Limpar arquivos temporários se existirem
        if [ -d "arquivos_template" ]; then
            print_message "Limpando arquivos temporários..."
            rm -rf arquivos_template
        fi

        # Perguntar se deve remover projeto parcialmente criado
        if [ -n "${PROJECT_NAME:-}" ] && [ -d "$PROJECT_NAME" ]; then
            if confirm "Deseja remover o projeto parcialmente criado '$PROJECT_NAME'?"; then
                rm -rf "$PROJECT_NAME"
                print_success "Projeto parcialmente criado removido"
            fi
        fi
    fi
}

# Função para setar o ruby padrão, caso seja asdf
configure_asdf_local_ruby() {
    print_step "Configurando versão local do Ruby (asdf)"

    # precisa do asdf
    if ! command -v asdf >/dev/null 2>&1; then
        print_debug "asdf não encontrado; ignorando configuração local"
        return 0
    fi

    # plugin ruby precisa existir
    if ! asdf plugin list 2>/dev/null | grep -qx "ruby"; then
        print_warning "asdf instalado, mas plugin 'ruby' não encontrado"
        print_message "Instale com: asdf plugin add ruby"
        return 0
    fi

    local ruby_version="$DEFAULT_RUBY_VERSION"

    # helper: checa se a versão está instalada
    asdf_ruby_installed() {
        # caminho direto: retorna 0 se instalada
        if asdf where ruby "$1" >/dev/null 2>&1; then
            return 0
        fi
        # fallback: normaliza saída (remove * e espaços) e compara exato
        asdf list ruby 2>/dev/null \
          | sed 's/^[[:space:]\*]*//' \
          | awk '{print $1}' \
          | grep -qx "$1"
    }

    if asdf_ruby_installed "$ruby_version"; then
        asdf local ruby "$ruby_version"
        print_success "asdf local ruby ${ruby_version} configurado no projeto"
    else
        print_warning "Ruby ${ruby_version} não está instalado no asdf"
        print_message "Instale com: asdf install ruby ${ruby_version}"
    fi
}


# Configurar trap para limpeza em caso de erro
trap cleanup_on_error EXIT

# ================================================================================
# FUNÇÕES DE VALIDAÇÃO
# ================================================================================

validate_project_name() {
    local name="$1"

    # Verificar se está vazio
    if [ -z "$name" ]; then
        print_error "Nome do projeto não pode estar vazio!"
        return 1
    fi

    # Verificar caracteres válidos (apenas letras, números, underscore e hífen)
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        print_error "Nome do projeto deve começar com letra e conter apenas letras, números, underscore e hífen!"
        return 1
    fi

    # Verificar se já existe
    if [ -d "$name" ]; then
        print_error "Diretório '$name' já existe!"
        return 1
    fi

    return 0
}

validate_template_file() {
    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Arquivo $TEMPLATE_FILE não encontrado no diretório atual!"
        print_message "Diretório atual: $(pwd)"
        return 1
    fi

    # Verificar se é um arquivo tar.gz válido
    if ! tar -tzf "$TEMPLATE_FILE" &> /dev/null; then
        print_error "Arquivo $TEMPLATE_FILE não é um arquivo tar.gz válido!"
        return 1
    fi

    print_success "Arquivo de template válido"
    return 0
}

# ================================================================================
# FUNÇÕES DE MODIFICAÇÃO DE ARQUIVOS
# ================================================================================

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}${BACKUP_SUFFIX}"
        print_debug "Backup criado: ${file}${BACKUP_SUFFIX}"
    fi
}

modify_application_controller() {
    local file="app/controllers/application_controller.rb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    backup_file "$file"

    # Adicionar código antes do último 'end'
    sed -i '/^end$/i\
\
  before_action if: -> { action_name == "index" } do\
    if session[:controller].nil? || session[:controller][:name] != controller_path.to_sym\
      session[:controller] = {}\
      session[:controller][:name] = controller_path.to_sym\
    end\
\
    base = [5, 10, 15, 20, 25]\
    params[:limit] = if params[:limit].to_i < 1\
                       session[:controller][:limit].presence || ApplicationRecord.page.limit_value\
                     elsif params[:limit].to_i <= base.last\
                       params[:limit].to_i\
                     else\
                       base.last\
                     end\
    session[:controller][:limit] = params[:limit]\
    @limites = [*base, params[:limit]].uniq.sort\
    session[:controller][:limites] = @limites\
    session[:controller][:url_att] = request.original_url\
\
    session[:controller][:search] = params[:q] if params[:q].present?\
    params[:q] = session[:controller][:search] if session[:controller][:search].present?\
    params[:q] = session[:controller][:search] = nil if params[:clear].present?\
  end\
\
  add_breadcrumb "Início", :root_path\
' "$file"

    print_success "ApplicationController modificado"
}

modify_application_js() {
    local file="app/javascript/application.js"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    cat >> "$file" << 'EOF'

import "jquery"
import "fomantic"

$(document).on('turbo:load', function () {
    $('.ui.dropdown').dropdown();
    $('.ui.accordion').accordion();
    $('.message .close')
        .on('click', function () {
            $(this)
                .closest('.message')
                .transition('fade')
            ;
        })
    ;
});
EOF

    print_success "application.js modificado"
}

modify_application_record() {
    local file="app/models/application_record.rb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    backup_file "$file"

    sed -i '/^end$/i\
\
  def self.ransackable_attributes(auth_object = nil)\
    column_names - %w[\
      encrypted_password\
      password_salt\
      password_hash\
      password_digest\
      password_reset_token\
      reset_password_token\
      reset_password_sent_at\
      remember_created_at\
      confirmation_token\
      confirmed_at\
      confirmation_sent_at\
      unconfirmed_email\
      unlock_token\
      locked_at\
      failed_attempts\
      owner\
      api_key\
      access_token\
      auth_token\
      secret_token\
      session_token\
      jwt_token\
      private_key\
      public_key\
    ]\
  end\
\
  def self.ransackable_associations(auth_object = nil)\
    reflect_on_all_associations.map(&:name).map(&:to_s)\
  end\
' "$file"

    print_success "ApplicationRecord modificado"
}

modify_application_layout() {
    local file="app/views/layouts/application.html.erb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    backup_file "$file"

    # Alterar <html> para <html lang="pt-BR">
    sed -i 's/<html>/<html lang="pt-BR">/' "$file"

    # Alterar estrutura do body
    sed -i 's|<%= yield %>|<div class="ui container">\
      <%= render partial: '\''layouts/flash_messages'\'' %>\
      <%= yield %>\
    </div>|' "$file"

    print_success "Layout da aplicação modificado"
}

modify_development_config() {
    local file="config/environments/development.rb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    # Adicionar configuração de hosts antes do último 'end'
    sed -i '/^end$/i\
\
  config.hosts = [\
    "localhost",\
    "127.0.0.1"\
  ]\
' "$file"

    print_success "Configuração de desenvolvimento modificada"
}

modify_application_config() {
    local file="config/application.rb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    backup_file "$file"

    sed -i '/config\.load_defaults/a\
\
    config.assets.prefix = "/desmonte/assets"\
\
    config.i18n.default_locale = :"pt-BR"\
    config.time_zone = "America/Fortaleza"\
    config.active_record.default_timezone = :local\
' "$file"

    print_success "Configuração da aplicação modificada"
}

modify_importmap() {
    local file="config/importmap.rb"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    cat >> "$file" << 'EOF'

pin "jquery", to: "fomantic/jquery-3.7.1.min.js"
pin "fomantic", to: "fomantic/semantic.min.js"
EOF

    print_success "Importmap modificado"
}

modify_gitignore() {
    local file=".gitignore"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    cat >> "$file" << 'EOF'

# Ignorar a pasta .idea do RubyMine
.idea/

# Ignorar backups
*.bak

# Ignorar logs do script
rails_project_creator.log
EOF

    print_success ".gitignore modificado"
}

modify_gemfile() {
    local file="Gemfile"

    if [ ! -f "$file" ]; then
        print_warning "Arquivo $file não encontrado"
        return 1
    fi

    backup_file "$file"

    # Adicionar gems antes de 'group :development, :test do'
    sed -i '/group :development, :test do/i\
# Authentication\
gem "devise", "~> 4.9", ">= 4.9.4"\
\
# Navigation\
gem "breadcrumbs_on_rails", "~> 4.1"\
\
# Search and pagination\
gem "ransack", "~> 4.3"\
gem "kaminari", "~> 1.2", ">= 1.2.2"\
\
# HTTP client\
gem "faraday", "~> 2.13", ">= 2.13.2"\
gem "faraday-retry", "~> 2.3", ">= 2.3.2"\
\
' "$file"

    # Adicionar rubocop dentro do group :development, :test
    sed -i '/group :development, :test do/,/^end/ {
        /^end/i\
  # Code quality\
  gem "rubocop", "~> 1.77", require: false\
  gem "rubocop-rails", require: false\
  gem "rubocop-performance", require: false
    }' "$file"

    print_success "Gemfile modificado"
}

# ================================================================================
# FUNÇÕES DE CÓPIA DE ARQUIVOS
# ================================================================================

copy_template_files() {
    print_step "Copiando arquivos de template"

    local source_dir="arquivos_template"
    local target_dir="$1"

    # Arrays de arquivos para copiar
    local directories_to_copy=(
        "fonts:app/assets/"
        "stylesheets/fomantic:app/assets/stylesheets/"
        "javascript/fomantic:app/javascript/"
        "services:app/"
        "kaminari:app/views/"
        "lib/templates:lib/"
    )

    local files_to_copy=(
        "flash_helper.rb:app/helpers/"
        "javascript/confirm_modal_controller.js:app/javascript/controllers/"
        "_errors_messages.html.erb:app/views/layouts/"
        "_flash_messages.html.erb:app/views/layouts/"
        "_pagination.html.erb:app/views/layouts/"
        "constants.rb:config/initializers/"
        "customize_error.rb:config/initializers/"
        "devise.rb:config/initializers/"
        "kaminari_config.rb:config/initializers/"
        "inflections.rb:config/initializers/"
        "devise.pt-BR.yml:config/locales/"
        "pt-BR.yml:config/locales/"
        ".tool-versions:"
        "cpf_cnpj_validators.rb:app/services/"
    )

    # Copiar diretórios
    for entry in "${directories_to_copy[@]}"; do
        IFS=':' read -r source dest <<< "$entry"
        if [ -d "$source_dir/$source" ]; then
            cp -r "$source_dir/$source" "$target_dir/$dest"
            print_success "Copiado: $source → $dest"
        else
            print_warning "Diretório não encontrado: $source"
        fi
    done

    # Copiar arquivos
    for entry in "${files_to_copy[@]}"; do
        IFS=':' read -r source dest <<< "$entry"
        if [ -f "$source_dir/$source" ]; then
            cp "$source_dir/$source" "$target_dir/$dest"
            print_success "Copiado: $source → $dest"
        else
            print_warning "Arquivo não encontrado: $source"
        fi
    done
}

# ================================================================================
# FUNÇÃO DE CRIAÇÃO DO PROJETO
# ================================================================================

create_rails_project() {
    local project_name="$1"
    local database="${2:-$DEFAULT_DATABASE}"
    local additional_options="${3:-}"

    print_step "Criando projeto Rails: $project_name"

    # Construir comando Rails
    local rails_command="rails new \"$project_name\" --database=$database"

    # Adicionar opções adicionais se fornecidas
    if [ -n "$additional_options" ]; then
        rails_command="$rails_command $additional_options"
    fi

    print_message "Executando: $rails_command"

    # Executar comando Rails
    if eval "$rails_command"; then
        print_success "Projeto Rails criado com sucesso!"
        return 0
    else
        print_error "Falha ao criar projeto Rails"
        return 1
    fi
}

# ================================================================================
# FUNÇÃO DE CONFIGURAÇÃO DO GIT
# ================================================================================

setup_git() {
    print_step "Configurando Git"

    if [ ! -d ".git" ]; then
        git init
        print_success "Repositório Git inicializado"
    fi

    # Fazer commit inicial
    git add .
    git commit -m "feat: commit inicial do projeto" || {
        print_warning "Nada para commitar no commit inicial"
    }

    print_success "Git configurado"
}

# ================================================================================
# FUNÇÃO DE GERAÇÃO DE README
# ================================================================================

generate_readme() {
    local project_name="$1"

    cat > README.md << EOF
# $project_name

## 📋 Sobre

Projeto Rails criado com template personalizado.

## 🚀 Tecnologias

- Ruby $DEFAULT_RUBY_VERSION
- Rails $DEFAULT_RAILS_VERSION
- PostgreSQL
- Fomantic UI
- Devise (autenticação)
- Kaminari (paginação)
- Ransack (busca)

## 🔧 Instalação

\`\`\`bash
# Instalar dependências
bundle install

# Configurar banco de dados
rails db:create
rails db:migrate

# Iniciar servidor
rails server
\`\`\`

## 📁 Estrutura do Projeto

- \`app/services/\` - Serviços da aplicação
- \`app/javascript/fomantic/\` - Arquivos do Fomantic UI
- \`config/locales/\` - Arquivos de tradução (pt-BR)

## 🤝 Contribuindo

1. Faça um fork do projeto
2. Crie sua feature branch (\`git checkout -b feature/AmazingFeature\`)
3. Commit suas mudanças (\`git commit -m 'Add some AmazingFeature'\`)
4. Push para a branch (\`git push origin feature/AmazingFeature\`)
5. Abra um Pull Request

## 📝 Licença

Este projeto está sob a licença MIT.

---

Criado em $(date '+%d/%m/%Y') usando rails_project_creator v$SCRIPT_VERSION
EOF

    print_success "README.md gerado"
}

# ================================================================================
# FUNÇÃO PRINCIPAL
# ================================================================================

main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        Rails Project Creator v$SCRIPT_VERSION                    ║"
    echo "║        Criador de Projetos Rails com Template           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    # Iniciar log
    log_message "=== Iniciando script v$SCRIPT_VERSION ==="

    # Verificar requisitos
    check_requirements

    # Verificar arquivo de template
    validate_template_file || exit 1

    # Obter nome do projeto
    local project_name=""
    if [ -z "${1:-}" ]; then
        while true; do
            read -p "$(echo -e "${BOLD}Digite o nome do projeto:${NC} ")" project_name
            if validate_project_name "$project_name"; then
                break
            fi
        done
    else
        project_name="$1"
        validate_project_name "$project_name" || exit 1
    fi

    # Opções adicionais
    local use_api_mode=false
    local skip_bundle=false

    if confirm "Deseja configurar opções adicionais para o projeto?"; then
        confirm "Modo API apenas (--api)?" && use_api_mode=true
        confirm "Pular bundle install inicial (--skip-bundle)?" && skip_bundle=true
    fi

    # Construir opções adicionais
    local additional_options=""
    [[ "$use_api_mode" == true ]] && additional_options="$additional_options --api"
    [[ "$skip_bundle" == true ]] && additional_options="$additional_options --skip-bundle"

    # Criar projeto Rails
    create_rails_project "$project_name" "$DEFAULT_DATABASE" "$additional_options" || exit 1

    # Entrar no diretório do projeto
    cd "$project_name"

    # Configurar Git
    setup_git

    # Voltar ao diretório anterior para acessar o template
    cd ..

    # Descompactar arquivo de template
    print_step "Descompactando arquivos de template"
    tar -xzf "$TEMPLATE_FILE" || {
        print_error "Falha ao descompactar o arquivo de template!"
        exit 1
    }

    # Verificar se foi descompactado corretamente
    if [ ! -d "arquivos_template" ]; then
        print_error "Diretório 'arquivos_template' não encontrado após descompactação!"
        exit 1
    fi

    # Copiar arquivos de template
    copy_template_files "$project_name"

    # Entrar no diretório do projeto para fazer as modificações
    cd "$project_name"

    # Configurar versão local do Ruby via asdf (se disponível)
    configure_asdf_local_ruby

    # Modificar arquivos existentes
    print_step "Modificando arquivos existentes"

    modify_application_controller
    modify_application_js
    modify_application_record
    modify_application_layout
    modify_development_config
    modify_application_config
    modify_importmap
    modify_gitignore
    modify_gemfile

    # Gerar README
    generate_readme "$project_name"

    # Commit das mudanças
    print_step "Finalizando configuração"

    git add .
    git commit -m "feat: adicionar template padrão e configurações" || {
        print_warning "Nada para commitar após aplicar template"
    }

    print_success "Commit das alterações realizado!"

    # Limpar pasta de template
    cd ..
    rm -rf arquivos_template
    print_success "Arquivos temporários removidos"

    # Mensagem final de sucesso
    echo -e "\n${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          🎉 PROJETO CRIADO COM SUCESSO! 🎉                ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    print_success "Projeto '$project_name' criado e configurado!"

    echo -e "\n${BOLD}Próximos passos:${NC}"
    echo -e "  ${CYAN}cd $project_name${NC}"
    echo -e "  ${CYAN}bundle install${NC}"
    echo -e "  ${CYAN}rails db:create${NC}"
    echo -e "  ${CYAN}rails db:migrate${NC}"
    echo -e "  ${CYAN}rails server${NC}"

    if [[ "$skip_bundle" == false ]]; then
        echo -e "\n${YELLOW}Dica:${NC} Execute 'bundle install' para instalar as gems adicionadas."
    fi

    echo -e "\n${BOLD}Recursos incluídos:${NC}"
    echo "  ✓ Fomantic UI para interface"
    echo "  ✓ Devise para autenticação"
    echo "  ✓ Kaminari para paginação"
    echo "  ✓ Ransack para busca"
    echo "  ✓ Localização pt-BR"
    echo "  ✓ Configurações personalizadas"

    log_message "=== Script finalizado com sucesso ==="

    # Desativar trap já que finalizou com sucesso
    trap - EXIT
}

# ================================================================================
# EXECUTAR SCRIPT
# ================================================================================

# Verificar se está sendo executado (não sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
