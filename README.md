# HerraizSergio-ASGBD

Repositorio de prácticas del módulo **Administración de Sistemas Gestores de Bases de Datos (ASGBD)** del ciclo ASIX.

- **Alumno:** Sergio Herraiz
- **Curso:** 2026-2027
- **Entorno de trabajo:** Windows 11, Docker Desktop (WSL 2), Git Bash

---

## Índice de prácticas

| Práctica | Descripción | SGBD | Estado | Documentación |
|---|---|---|---|---|
| **P1** | Despliegue y administración de un servidor de base de datos con Docker: red, memoria, conexiones, almacenamiento, trazabilidad y control de accesos | PostgreSQL 16.4 | En desarrollo | [p1/README.md](p1/README.md) |

---

## Estructura del repositorio

```text
HerraizSergio-ASGBD/
├── README.md              # Este documento (visión general)
├── docker-compose.yml     # Compose general del repositorio
├── .gitignore             # Excluye contraseñas (.env) y ficheros de editor
└── p1/
    ├── README.md          # Documentación completa de la práctica 1
    ├── docker-compose.yml # Despliegue específico de la P1
    ├── setup-env.sh       # Monta todo el escenario de la P1
    ├── .env.example       # Plantilla de variables (sin valores reales)
    ├── conf/
    │   ├── postgresql.conf
    │   └── pg_hba.conf
    ├── sql/
    │   ├── 01-estructura.sql
    │   └── 02-roles-privilegios.sql
    └── img/               # Capturas usadas en la documentación
```

---

## Requisitos previos

| Herramienta | Para qué se usa | Comprobación |
|---|---|---|
| Git | Control de versiones y entrega | `git --version` |
| Docker Desktop (con WSL 2) | Ejecutar los contenedores | `docker version` |
| Docker Compose v2 | Describir el despliegue | `docker compose version` |
| Bash (Git Bash en Windows) | Ejecutar `setup-env.sh` | `bash --version` |

> **Importante en Windows:** `setup-env.sh` debe tener finales de línea **LF**, no CRLF.
> Se evita con `git config core.autocrlf input`.

---

## Cómo desplegar la práctica desde un clon limpio

```bash
# 1. Clonar el repositorio
git clone https://github.com/fpmislata-asix2-asgbd/HerraizSergio-ASGBD.git
cd HerraizSergio-ASGBD/p1

# 2. Crear el fichero de contraseñas a partir de la plantilla
cp .env.example .env
nano .env        # poner contraseñas reales

# 3. Montar todo el escenario
./setup-env.sh
```

El script es **idempotente**: si la base de datos ya existe, no repite la inicialización.

Para destruirlo todo, **incluidos los datos**:

```bash
cd p1
docker compose down -v
```

---

## Gestión de contraseñas

Ninguna contraseña se sube al repositorio.

| Fichero | ¿Se sube a Git? | Contenido |
|---|---|---|
| `p1/.env.example` | Sí | Nombres de variables con el valor `cambiame` |
| `p1/.env` | **No** (ignorado) | Contraseñas reales |

Comprobación de que `.env` está ignorado:

```bash
git check-ignore -v p1/.env
```

---

## Flujo de trabajo con Git

```bash
git add .
git status                      # comprobar que p1/.env NO aparece
git commit -m "Mensaje descriptivo"
git push
```

Entrega de cada práctica mediante etiqueta:

```bash
git tag P1
git push --tags
```

Enlace de entrega:
`https://github.com/fpmislata-asix2-asgbd/HerraizSergio-ASGBD/tree/P1/p1/README.md`

---

## Notas del entorno

Este equipo se utiliza también para otras asignaturas, por lo que existen contenedores ajenos a esta práctica (WordPress, phpMyAdmin, MariaDB, `erp_postgres`).
Por ese motivo:

- **No** se usa `docker system prune` ni `--remove-orphans`.
- El proyecto de Compose se llama `asgbd-p1` para no mezclarse con otros proyectos.
