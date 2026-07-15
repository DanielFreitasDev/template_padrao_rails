# Rails Project Creator

Gerador de projetos Ruby on Rails com o template padrão da empresa. Cria um
projeto novo já configurado com a nossa stack, pronto para `bin/rails server`.

- **Ruby 4.0.6** (instalado automaticamente via [mise](https://mise.jdx.dev))
- **Rails 8.1.3** (a gem é instalada se não existir)
- **PostgreSQL** como banco padrão
- **Fomantic UI 2.9.4** + jQuery 3.7.1 vendorizados (sem Node, sem CDN)
- **Devise** (autenticação) · **Kaminari** (paginação) · **Ransack** (busca) · **Breadcrumbs on Rails**
- Localização **pt-BR** (locales, inflexões de plural) e fuso **America/Fortaleza**
- **Scaffold personalizado**: `bin/rails g scaffold ...` já gera telas no padrão
  Fomantic com filtro de busca, paginação com limite por página e breadcrumbs

## Pré-requisitos

- Linux com `bash`, `git` e `tar`
- [mise](https://mise.jdx.dev) (recomendado — o script instala o Ruby sozinho).
  Sem mise, o script aceita asdf ou o Ruby do sistema, avisando se a versão divergir.
- PostgreSQL rodando (para o banco padrão; use `-d` para outro banco)

## Uso

```bash
./rails_project_creator.sh                  # modo interativo
./rails_project_creator.sh meuapp -y        # sem perguntas, tudo padrão
```

| Opção | Descrição |
| --- | --- |
| `-d, --database BANCO` | Banco de dados (padrão: `postgresql`) |
| `--api` | Projeto em modo API (sem views/assets/Fomantic) |
| `--skip-bundle` | Não roda `bundle install` (a parte JS fica pendente) |
| `--ruby VERSAO` | Versão do Ruby (padrão: 4.0.6) |
| `--rails VERSAO` | Versão do Rails (padrão: 8.1.3) |
| `--prefix VALOR` | Prefixo dos assets p/ deploy em subcaminho (padrão: nome do projeto; `none` desativa) |
| `-y, --yes` | Assume "sim" para tudo (não interativo) |
| `-h, --help` | Ajuda completa |

Depois de criado:

```bash
cd meuapp
bin/rails db:prepare
bin/rails server
```

O README gerado dentro do projeto traz o checklist inicial (ajustar
`mailer_sender` do Devise, gerar o model de usuário, definir a rota raiz).

## Como funciona

Dois arquivos, duas responsabilidades:

- **`rails_project_creator.sh`** — wrapper de ambiente: resolve o Ruby
  (mise → asdf → sistema), garante a gem do Rails, extrai o tarball em
  diretório temporário, roda o `rails new` e faz o commit inicial.
- **`arquivos_template.tar.gz`** — contém `arquivos_template/template.rb`
  (um [Rails application template](https://guides.rubyonrails.org/rails_application_templates.html)
  aplicado via `rails new -m`) e os arquivos copiados para o projeto
  (Fomantic, locales, initializers, scaffold templates, services etc.).

O template também funciona sem o script, se precisar:

```bash
tar -xzf arquivos_template.tar.gz
rails new meuapp -d postgresql -m arquivos_template/template.rb
```

## Manutenção do template

- **Versões padrão** (Ruby/Rails/banco): constantes no topo do
  `rails_project_creator.sh`.
- **Arquivos do template**: extrair, editar e reempacotar —

  ```bash
  tar -xzf arquivos_template.tar.gz
  # editar arquivos_template/...
  tar -czf arquivos_template.tar.gz arquivos_template
  rm -rf arquivos_template
  ```

- O `.tool-versions` do projeto **não** fica no tarball — é gerado pelo script
  com a versão de Ruby em uso (evita divergência de versões).
- `config/initializers/constants.rb` contém os endpoints e chaves dos
  webservices internos, **compartilhados de propósito** entre os projetos da
  equipe (rede interna).

## Estrutura do repositório

```
├── rails_project_creator.sh   # script principal (v3.0.0)
├── arquivos_template.tar.gz   # template.rb + arquivos do template
├── backup_v2/                 # versão anterior (v2), para referência
└── README.md
```

O script grava um log de execução em `rails_project_creator.log`
(ignorado pelo git).
