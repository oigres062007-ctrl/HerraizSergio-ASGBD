#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "Falta .env (copia .env.example a .env)"; exit 1; }
set -a; source .env; set +a

### CONTENIDORES
docker compose up -d --wait

### SQL
PSQL=(docker exec -i empresa-db psql -U postgres -v ON_ERROR_STOP=1
      -v erp_pwd="$ERP_APP_PASSWORD" -v user_pwd="$INITIAL_USER_PASSWORD")

# Idempotente: solo inicializa si la base de datos no existe
if [ "$("${PSQL[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname='empresa'")" != "1" ]; then
  for f in sql/0*.sql; do
    echo ">> Ejecutando $f"
    "${PSQL[@]}" < "$f"
  done
else
  echo "La base de datos 'empresa' ya existe: se omite la inicialización."
fi

echo "Entorno listo."
