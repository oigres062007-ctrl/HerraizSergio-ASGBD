# Práctica 1: Servidor de base de datos con Docker (PostgreSQL 16.4)

Documentación completa del despliegue, la configuración y el control de acceso de un servidor PostgreSQL para una empresa ficticia con un ERP y personal que trabaja directamente con la base de datos.

- **Autor:** Sergio Herraiz
- **SGBD elegido:** PostgreSQL 16.4
- **Contenedor:** `empresa-db`
- **Proyecto Compose:** `asgbd-p1`

---

## Tabla resumen

| Requisito | Cómo se ha resuelto | Evidencia |
|---|---|---|
| **1. Despliegue reproducible** | `docker-compose.yml` con imagen `postgres:16.4`, 2 redes, 4 volúmenes y límite de 2 GB. Contraseñas en `.env` (ignorado por Git). Todo se monta con `setup-env.sh` | [Apartado 1](#1-despliegue-reproducible) |
| **2. Acceso restringido a la red interna** | `pg_hba.conf` con `reject` explícito para `172.31.0.0/24`. Servidor en las dos redes y sin puertos publicados | [Apartado 2](#2-acceso-restringido-a-la-red-interna) |
| **3. Memoria** | `shared_buffers` 512 MB, `work_mem` 4 MB, `maintenance_work_mem` 32 MB, `wal_buffers` 16 MB. Peor caso calculado: 1731 MB de 2048 MB | [Apartado 3](#3-memoria) |
| **4. Conexiones** | `max_connections = 55` (50 necesarias + 3 reservadas + 2 de margen) | [Apartado 4](#4-conexiones) |
| **5. Almacenamiento** | Tablespaces `tbs_erp` y `tbs_empleados` en volúmenes distintos | [Apartado 5](#5-almacenamiento) |
| **6. Trazabilidad** | `logging_collector` escribe en un volumen persistente. Los rechazos quedan registrados | [Apartado 6](#6-trazabilidad) |
| **7. Cuenta de la aplicación** | `erp_app` con solo DML, límite de 45 conexiones y sin caducidad. Propietarios `NOLOGIN` | [Apartado 7](#7-cuenta-de-la-aplicacion) |
| **8. Acceso del personal** | Roles `rol_rrhh` y `rol_analista`. Privilegio por columna para ocultar el salario. Caducidad a 90 días | [Apartado 8](#8-acceso-del-personal) |
| **9. Ampliación: caída súbita** (opcional) | Reinicio automático configurado. Pruebas pendientes de documentar | [Apartado 9](#9-ampliacion-caida-subita-opcional) |

---

## Convenciones de este documento

- Los comandos se ejecutan desde la carpeta `p1/` con las variables del `.env` cargadas:

  ```bash
  set -a; source .env; set +a
  ```

- Las contraseñas aparecen siempre como variables (`$ERP_APP_PASSWORD`), nunca con su valor real.
- Las salidas que se muestran son **texto copiado de la terminal**, obtenido consultando al servidor. Las capturas de la carpeta `img/` son un apoyo visual.
- En Git Bash las rutas que empiezan por `/` se convierten a rutas de Windows. Por eso los comandos que usan rutas del contenedor van dentro de `sh -c '...'`, lo que además los hace portables a Linux.

---

## 0. Decisiones generales

### Por qué PostgreSQL

| Criterio | Decisión |
|---|---|
| Peso de la imagen y arranque | Más ligera y rápida de arrancar que Oracle |
| Control de acceso por red | `pg_hba.conf` encaja directamente con el requisito 2: rechazo por parte del SGBD |
| Tablespaces | Se crean con una sola sentencia apuntando a un directorio |
| Roles y privilegios | Los roles son el mecanismo nativo de grupos de privilegios, y admite privilegios por columna |
| Licencia | Libre, sin restricciones para una práctica |

### Estructura del repositorio

```text
p1/
├── README.md
├── docker-compose.yml
├── setup-env.sh
├── .env.example
├── conf/
│   ├── postgresql.conf
│   └── pg_hba.conf
├── sql/
│   ├── 01-estructura.sql
│   └── 02-roles-privilegios.sql
└── img/
```

### Fichero `.env.example`

```bash
POSTGRES_PASSWORD=cambiame
ERP_APP_PASSWORD=cambiame
INITIAL_USER_PASSWORD=cambiame
```

---

## 1. Despliegue reproducible

**Necesidad:** si el servidor se pierde, debe poder recrearse rápido y con los mismos datos.

### 1.1 `docker-compose.yml`

```yaml
name: asgbd-p1

services:
  init-perms:
    image: alpine:3.20
    user: root
    command: chown -R 999:999 /tbs/erp /tbs/empleados /logs
    volumes:
      - vol_erp:/tbs/erp
      - vol_empleados:/tbs/empleados
      - vol_logs:/logs

  db:
    container_name: empresa-db
    image: postgres:16.4
    restart: unless-stopped
    command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      init-perms:
        condition: service_completed_successfully
    mem_limit: 2g
    memswap_limit: 2g
    shm_size: 512m
    networks: [interna, visitantes]
    volumes:
      - ./conf:/etc/postgresql:ro
      - vol_pgdata:/var/lib/postgresql/data
      - vol_erp:/tablespaces/erp
      - vol_empleados:/tablespaces/empleados
      - vol_logs:/var/log/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -U postgres"]
      interval: 2s
      timeout: 5s
      retries: 30
      start_period: 10s

networks:
  interna:
    name: p1_interna
    ipam:
      config:
        - subnet: 172.30.0.0/24
  visitantes:
    name: p1_visitantes
    ipam:
      config:
        - subnet: 172.31.0.0/24

volumes:
  vol_pgdata:
  vol_erp:
  vol_empleados:
  vol_logs:
```

### 1.2 Justificación de cada decisión

| Decisión | Motivo |
|---|---|
| `postgres:16.4` | Versión fijada, nunca `latest`, para que el despliegue sea reproducible |
| 4 volúmenes | Datos del servidor, ERP, empleados y logs separados, como exige el enunciado |
| Sin `ports:` | No se publica ningún puerto en el host |
| `mem_limit: 2g` | El contenedor no puede usar más de los 2 GB del enunciado |
| `memswap_limit: 2g` | Sin swap: si se supera la memoria, Docker mata el contenedor y el límite es real |
| `shm_size: 512m` | PostgreSQL usa `/dev/shm` y los 64 MB por defecto se quedan cortos |
| `init-perms` | Los volúmenes nuevos pertenecen a root. PostgreSQL exige que los directorios de tablespaces y logs sean del usuario `postgres` (uid 999) |
| Subredes fijas | Reproducen las del enunciado: `172.30.0.0/24` y `172.31.0.0/24` |
| `restart: unless-stopped` | Reinicio automático si el proceso cae (ampliación) |
| `healthcheck` por TCP | Durante la inicialización el servidor temporal solo escucha por socket Unix, por lo que se comprueba por `127.0.0.1` |
| Conf montada como solo lectura | La configuración vive en el repositorio y el contenedor no puede alterarla |

### 1.3 Contraseñas fuera del repositorio

`.gitignore` (raíz del repositorio):

```text
.env
**/.env
.DS_Store
Thumbs.db
.vscode/
.idea/
```

```bash
git check-ignore -v p1/.env
```

![Comprobación de que .env está ignorado](img/img1.png)

### 1.4 Script `setup-env.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "Falta .env (copia .env.example a .env)"; exit 1; }
set -a; source .env; set +a

### CONTENEDORES
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
```

**Por qué es idempotente:** si se lanza dos veces, la segunda detecta que `empresa` existe y no intenta recrear roles y tablespaces (daría error).

### 1.5 Evidencia: montaje desde cero

```bash
docker compose down -v
./setup-env.sh
```

```text
 ✔ Volume p1_vol_erp         Created
 ✔ Volume p1_vol_empleados   Created
 ✔ Volume p1_vol_pgdata      Created
 ✔ Network p1_interna        Created
 ✔ Network p1_visitantes     Created
 ✔ Volume p1_vol_logs        Created
 ✔ Container p1-init-perms-1 Exited
 ✔ Container empresa-db      Healthy
>> Ejecutando sql/01-estructura.sql
CREATE ROLE
CREATE ROLE
CREATE TABLESPACE
CREATE TABLESPACE
CREATE DATABASE
...
>> Ejecutando sql/02-roles-privilegios.sql
...
Entorno listo.
```

> La salida original se hizo con el nombre de proyecto anterior (`p1`). Hoy los volúmenes se llaman `asgbd-p1_vol_*` (véase el apartado de problemas).

![Montaje desde cero con setup-env.sh](img/img2.png)

### 1.6 Evidencia: versión, puertos, memoria y redes

```bash
docker compose ps
docker port empresa-db
docker inspect empresa-db -f 'Memoria: {{.HostConfig.Memory}}  Swap total: {{.HostConfig.MemorySwap}}'
docker inspect empresa-db -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}: {{$v.IPAddress}}{{"\n"}}{{end}}'
docker network inspect p1_interna p1_visitantes --format '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}}{{end}}'
docker exec empresa-db psql -U postgres -c "SELECT version();"
```

```text
NAME         IMAGE           COMMAND                  SERVICE   STATUS                    PORTS
empresa-db   postgres:16.4   "docker-entrypoint.s…"   db        Up 29 seconds (healthy)   5432/tcp

(docker port: sin salida, no hay puertos publicados)

Memoria: 2147483648  Swap total: 2147483648

p1_interna: 172.30.0.2
p1_visitantes: 172.31.0.2

p1_interna: 172.30.0.0/24
p1_visitantes: 172.31.0.0/24

PostgreSQL 16.4 (Debian 16.4-1.pgdg120+2) on x86_64-pc-linux-gnu, compiled by gcc (Debian 12.2.0-14) 12.2.0, 64-bit
```

| Comprobación | Resultado | Conclusión |
|---|---|---|
| `PORTS` | `5432/tcp` sin `->` | Expuesto solo dentro de las redes de Docker |
| `docker port` | Vacío | Ningún puerto publicado en el host |
| Memoria y swap | 2147483648 (= 2 GiB) ambos | Límite real, sin swap |
| IPs | `172.30.0.2` y `172.31.0.2` | Conectado a las dos redes |

![Estado, puertos, memoria y redes](img/img3.png)

### 1.7 Evidencia: destruir el servidor y conservar los datos

```bash
docker exec empresa-db psql -U postgres -d empresa -c "SELECT count(*) FROM erp.clientes;"
docker compose down
docker compose up -d --wait
docker exec empresa-db psql -U postgres -d empresa -c "SELECT count(*) FROM erp.clientes;"
```

```text
 count
-------
     2

 ✔ Container empresa-db      Removed
 ✔ Network p1_visitantes     Removed
 ✔ Network p1_interna        Removed
 ...
 ✔ Container empresa-db      Healthy

 count
-------
     2
```

`docker compose down` elimina contenedores y redes pero **no los volúmenes**. Al recrear el contenedor, PostgreSQL reutiliza los datos de `vol_pgdata`.

![Persistencia tras destruir el contenedor](img/img4.png)

---

## 2. Acceso restringido a la red interna

**Necesidad:** solo el ERP y el personal de la red interna pueden conectarse. Ningún cliente de la red de visitantes, aunque tenga ruta al servidor.

### 2.1 `pg_hba.conf`

```conf
# TYPE  DATABASE  USER  ADDRESS         METHOD
local   all       all                   trust
host    all       all   127.0.0.1/32    scram-sha-256
host    all       all   172.31.0.0/24   reject
host    all       all   172.30.0.0/24   scram-sha-256
host    all       all   0.0.0.0/0       reject
```

PostgreSQL lee las reglas de arriba abajo y aplica **la primera que coincide**. Por eso el orden importa.

| Línea | Función |
|---|---|
| `local ... trust` | Solo es alcanzable con `docker exec` dentro del contenedor. Lo necesita el arranque inicial de la imagen |
| `127.0.0.1/32 scram` | La usa el healthcheck |
| `172.31.0.0/24 reject` | **Rechazo explícito** de la red de visitantes, que además deja constancia clara en el log |
| `172.30.0.0/24 scram` | Red interna: se permite con contraseña cifrada (SCRAM-SHA-256) |
| `0.0.0.0/0 reject` | Denegación por defecto de cualquier otro origen |

### 2.2 Regla cargada en el servidor

```bash
docker exec empresa-db psql -U postgres -c "SELECT line_number, type, address, auth_method FROM pg_hba_file_rules;"
```

![Reglas de pg_hba cargadas](img/img5.png)

### 2.3 Cliente de la red interna: conecta

```bash
docker run --rm --network p1_interna -e PGPASSWORD="$INITIAL_USER_PASSWORD" \
  postgres:16.4 psql -h db -U analista1 -d empresa \
  -c "SELECT current_user, inet_client_addr(), inet_server_addr();"
```

![Cliente interno conectado](img/img6.png)

### 2.4 Cliente de la red de visitantes: rechazado por el SGBD

Primero se demuestra que **hay ruta de red**: el servidor responde.

```bash
docker run --rm --network p1_visitantes postgres:16.4 pg_isready -h db
```

```text
db:5432 - accepting connections
```

Después se intenta autenticar:

```bash
docker run --rm --network p1_visitantes -e PGPASSWORD="$INITIAL_USER_PASSWORD" \
  postgres:16.4 psql -h db -U analista1 -d empresa -c "SELECT 1;"
```

```text
psql: error: connection to server at "db" (172.31.0.2), port 5432 failed: FATAL:  pg_hba.conf rejects connection for host "172.31.0.3", user "analista1", database "empresa", no encryption
```

**Conclusión:** la red permite llegar al servidor (`accepting connections`), pero el mensaje procede de `pg_hba.conf`. El rechazo es una decisión del SGBD, no una ausencia de ruta.

![Visitante rechazado por pg_hba.conf](img/img7.png)

---

## 3. Memoria

**Necesidad:** aprovechar los 2 GB sin quedarse cortos ni pasarse. Si el servidor supera el límite del contenedor, Docker lo mata.

### 3.1 Parámetros elegidos

| Clase | Parámetro | Valor | Cuándo se reserva |
|---|---|---|---|
| Compartida | `shared_buffers` | 512 MB | Una vez, al arrancar (caché de datos). 25 % de 2 GB |
| Compartida | `wal_buffers` | 16 MB | Una vez, al arrancar |
| Por operación | `work_mem` | 4 MB | Por cada ordenación o hash, de cada sesión |
| Por operación | `hash_mem_multiplier` | 1.0 | Evita que las operaciones hash usen más que `work_mem` y hace el cálculo predecible |
| Mantenimiento | `maintenance_work_mem` | 32 MB | `VACUUM`, `CREATE INDEX` |
| Solo planificador | `effective_cache_size` | 1 GB | No reserva memoria: es una pista para el planificador |

### 3.2 Cálculo del peor caso

Sesiones de usuario posibles: 55 − 3 reservadas = **52**. Se supone un máximo de 3 nodos de ordenación o hash simultáneos por consulta.

| Concepto | Cálculo | MB |
|---|---|---|
| `shared_buffers` | fijo | 512 |
| Otras estructuras compartidas (WAL, locks...) | estimación | 64 |
| Mantenimiento | 32 MB × 4 (1 manual + 3 autovacuum) | 128 |
| Base por proceso backend | 55 × ~5 MB | 275 |
| `work_mem` | 52 sesiones × 3 nodos × 4 MB | 624 |
| Sistema operativo y procesos internos | estimación | 128 |
| **Total** | | **1731** |
| **Margen** | 2048 − 1731 | **317 (≈ 15 %)** |

**Por qué influye el número de conexiones:** `work_mem` se multiplica por sesiones y por nodos. Con 200 conexiones el mismo cálculo daría 2400 MB solo de `work_mem`, y Docker mataría el contenedor. El valor de `max_connections` y el de `work_mem` se deciden a la vez.

Las cifras marcadas como «estimación» (64, 128, ~5 MB por backend) son aproximaciones prudentes, no mediciones.

### 3.3 Valores en uso

```bash
docker exec empresa-db psql -U postgres -c "SELECT name, setting, unit, context, pending_restart FROM pg_settings WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','max_connections','wal_buffers','hash_mem_multiplier','effective_cache_size');"
docker stats --no-stream empresa-db
```

```text
         name         | setting | unit |  context   | pending_restart
----------------------+---------+------+------------+-----------------
 effective_cache_size | 131072  | 8kB  | user       | f
 hash_mem_multiplier  | 1       |      | user       | f
 maintenance_work_mem | 32768   | kB   | user       | f
 max_connections      | 55      |      | postmaster | f
 shared_buffers       | 65536   | 8kB  | postmaster | f
 wal_buffers          | 2048    | 8kB  | postmaster | f
 work_mem             | 4096    | kB   | user       | f
(7 rows)

CONTAINER ID   NAME         CPU %     MEM USAGE / LIMIT   MEM %     NET I/O         BLOCK I/O    PIDS
9de5fb35487f   empresa-db   0.05%     40.15MiB / 2GiB     1.96%     2.34kB / 252B   0B / 578kB   7
```

### 3.4 Tabla de entrega

| Parámetro | Valor en `pg_settings` | Equivalencia | Cálculo que lo justifica | Contexto |
|---|---|---|---|---|
| `shared_buffers` | 65536 (8 kB) | 512 MB | 25 % de 2 GB | `postmaster` (reinicio) |
| `wal_buffers` | 2048 (8 kB) | 16 MB | Valor habitual para cargas con escrituras | `postmaster` (reinicio) |
| `work_mem` | 4096 kB | 4 MB | 52 × 3 × 4 MB = 624 MB | `user` (sin reinicio) |
| `maintenance_work_mem` | 32768 kB | 32 MB | 4 procesos × 32 MB = 128 MB | `user` (sin reinicio) |
| `hash_mem_multiplier` | 1 | 1.0 | Hace predecible el peor caso | `user` (sin reinicio) |
| `max_connections` | 55 | 55 | Véase apartado 4 | `postmaster` (reinicio) |
| `effective_cache_size` | 131072 (8 kB) | 1 GB | Pista al planificador, no reserva | `user` (sin reinicio) |

**Sobre `docker stats`:** en reposo el contenedor usa 40 MiB, muy por debajo de los 2 GiB. No contradice el cálculo: los 1731 MB son el **peor caso** (todas las sesiones al máximo a la vez), no el uso normal. `shared_buffers` se reserva como espacio de direcciones pero el sistema operativo no asigna las páginas hasta que se tocan.

![Parámetros de memoria en uso](img/img8.png)

### 3.5 Parámetro que se cambia SIN reiniciar: `work_mem`

```bash
docker exec empresa-db psql -U postgres -c "SHOW work_mem;"
docker exec empresa-db psql -U postgres -c "ALTER SYSTEM SET work_mem='8MB';"
docker exec empresa-db psql -U postgres -c "SELECT pg_reload_conf();"
docker exec empresa-db psql -U postgres -c "SHOW work_mem;"
```

```text
 work_mem
----------
 4MB

ALTER SYSTEM

 pg_reload_conf
----------------
 t

 work_mem
----------
 8MB
```

El valor pasa de `4MB` a `8MB` con un simple `pg_reload_conf()`, sin reiniciar el servidor. Su contexto es `user`.

![work_mem cambiado sin reinicio](img/img9.png)

### 3.6 Parámetro que REQUIERE reinicio: `shared_buffers`

```bash
docker exec empresa-db psql -U postgres -c "ALTER SYSTEM SET shared_buffers='256MB';"
docker exec empresa-db psql -U postgres -c "SELECT pg_reload_conf();"
docker exec empresa-db psql -U postgres -c "SHOW shared_buffers;"
docker exec empresa-db psql -U postgres -c "SELECT name, setting, pending_restart FROM pg_settings WHERE name='shared_buffers';"
docker restart empresa-db
docker exec empresa-db psql -U postgres -c "SHOW shared_buffers;"
```

```text
ALTER SYSTEM

 pg_reload_conf
----------------
 t

 shared_buffers
----------------
 512MB

      name      | setting | pending_restart
----------------+---------+-----------------
 shared_buffers | 65536   | t

empresa-db

 shared_buffers
----------------
 256MB
```

Tras recargar, el valor en uso **sigue siendo 512MB** y `pending_restart = t` indica que hay un cambio pendiente. Solo cambia a `256MB` después de reiniciar el contenedor. Su contexto es `postmaster`.

![shared_buffers solo cambia tras reiniciar](img/img10.png)

### 3.7 Limpieza: volver a los valores calculados

`ALTER SYSTEM` escribe en `postgresql.auto.conf`, dentro del volumen de datos, y ese fichero **tiene prioridad** sobre `postgresql.conf`. Si no se limpia, los valores de prueba se quedarían para siempre.

```bash
docker exec empresa-db psql -U postgres -c "ALTER SYSTEM RESET ALL;"
docker restart empresa-db
docker exec empresa-db psql -U postgres -c "SHOW work_mem;" -c "SHOW shared_buffers;"
```

```text
 work_mem
----------
 4MB

 shared_buffers
----------------
 512MB
```

---

## 4. Conexiones

**Necesidad:** admitir todas las conexiones simultáneas que puedan abrir el ERP y el personal, pero no más de las necesarias.

### 4.1 Cálculo

| Concepto | Cálculo | Conexiones |
|---|---|---|
| ERP | 3 instancias × 15 conexiones | 45 |
| Personal de RRHH | 2 personas | 2 |
| Analistas | 3 personas | 3 |
| **Subtotal simultáneo** | | **50** |
| Reservadas al superusuario | `superuser_reserved_connections` | 3 |
| Margen | holgura mínima | 2 |
| **`max_connections`** | 50 + 3 + 2 | **55** |

Para usuarios normales quedan 52 conexiones (55 − 3), que cubren las 50 necesarias.

**Por qué no más:** cada conexión extra cuesta memoria (~5 MB de base más `work_mem` por operación), y eso entra en el cálculo de los 2 GB.

**Por qué reservar 3:** permiten que el DBA entre aunque el servidor esté lleno de sesiones, que es justo cuando hace falta diagnosticar.

### 4.2 Valores en uso

```bash
docker exec empresa-db psql -U postgres -c "SHOW max_connections;" -c "SHOW superuser_reserved_connections;"
```

![Valores de max_connections](img/img11.png)

### 4.3 Superar el límite

Se lanzan 60 sesiones simultáneas de `analista1`:

```bash
docker run --rm --network p1_interna -e PGPASSWORD="$INITIAL_USER_PASSWORD" \
  postgres:16.4 bash -c '
for i in $(seq 1 60); do
  psql -h db -U analista1 -d empresa -c "select pg_sleep(20)" >/dev/null 2>>/tmp/err &
done
sleep 8
echo "--- Errores recibidos:"
sort /tmp/err | uniq -c
wait'
```

```text
--- Errores recibidos:
      9 psql: error: connection to server at "db" (172.30.0.2), port 5432 failed: FATAL:  remaining connection slots are reserved for roles with the SUPERUSER attribute
```

| Dato | Valor |
|---|---|
| Intentos simultáneos | 60 |
| Rechazados | 9 |
| Admitidos | 51 |
| Error | `remaining connection slots are reserved for roles with the SUPERUSER attribute` |

**Interpretación:** el servidor rechaza las conexiones cuando se agotan las ranuras de usuarios normales y solo quedan las reservadas.

**Nota sobre la cifra exacta:** con 52 ranuras normales cabría esperar 8 rechazos y no 9. No he verificado la causa de esa diferencia de una unidad. Para dejarlo comprobado se puede contar, durante la prueba, las sesiones abiertas con `SELECT count(*), backend_type FROM pg_stat_activity GROUP BY 2;`. Lo relevante para el requisito es que el servidor rechaza al superar el límite y muestra el error correspondiente.

![Superación del límite de conexiones](img/img12.png)

---

## 5. Almacenamiento

**Necesidad:** al menos dos tablespaces (ERP y empleados) en volúmenes distintos, con datos que sobreviven a un reinicio.

### 5.1 Diseño

| Tablespace | Ruta en el contenedor | Volumen Docker | Propietario | Contenido |
|---|---|---|---|---|
| `tbs_erp` | `/tablespaces/erp` | `asgbd-p1_vol_erp` | `erp_owner` | Esquema `erp` |
| `tbs_empleados` | `/tablespaces/empleados` | `asgbd-p1_vol_empleados` | `emp_owner` | Esquema `empleados` |

### 5.2 Scripts SQL de estructura (`sql/01-estructura.sql`)

```sql
-- Propietarios de los datos: nadie se conecta con ellos (NOLOGIN)
CREATE ROLE erp_owner NOLOGIN;
CREATE ROLE emp_owner NOLOGIN;

-- Tablespaces en volúmenes distintos
CREATE TABLESPACE tbs_erp       OWNER erp_owner LOCATION '/tablespaces/erp';
CREATE TABLESPACE tbs_empleados OWNER emp_owner LOCATION '/tablespaces/empleados';

CREATE DATABASE empresa;
REVOKE ALL ON DATABASE empresa FROM PUBLIC;

\connect empresa
REVOKE ALL ON SCHEMA public FROM PUBLIC;

CREATE SCHEMA erp       AUTHORIZATION erp_owner;
CREATE SCHEMA empleados AUTHORIZATION emp_owner;

-- Tablas e índices del ERP, en su tablespace
SET default_tablespace = tbs_erp;
SET ROLE erp_owner;
CREATE TABLE erp.clientes (id serial PRIMARY KEY, nombre text NOT NULL);
CREATE TABLE erp.pedidos  (id serial PRIMARY KEY,
                           cliente_id int REFERENCES erp.clientes(id),
                           importe numeric(10,2));
INSERT INTO erp.clientes(nombre) VALUES ('ACME'), ('Globex');
INSERT INTO erp.pedidos(cliente_id, importe) VALUES (1, 100.50), (2, 250.00);
RESET ROLE;

-- Tablas e índices de empleados, en el suyo
SET default_tablespace = tbs_empleados;
SET ROLE emp_owner;
CREATE TABLE empleados.empleados (id serial PRIMARY KEY, nombre text NOT NULL,
                                  departamento text, salario numeric(10,2));
INSERT INTO empleados.empleados(nombre, departamento, salario)
VALUES ('Ana','RRHH',2500), ('Luis','IT',3100), ('Marta','Ventas',2800);
RESET ROLE;
```

**Decisiones:**

- Los propietarios son `NOLOGIN`: nadie ni ninguna aplicación se conecta con ellos.
- `SET default_tablespace` antes de crear las tablas asegura que **también los índices** de las claves primarias queden en el tablespace correcto.
- `REVOKE ALL ... FROM PUBLIC` cierra los permisos que PostgreSQL concede por defecto a cualquiera.
- La columna `salario` ya existe en la tabla de empleados, como pedía el enunciado.

### 5.3 Dónde está cada espacio (diccionario de datos)

```bash
docker exec empresa-db psql -U postgres -c "SELECT spcname, pg_tablespace_location(oid) AS ubicacion, pg_get_userbyid(spcowner) AS propietario FROM pg_tablespace;"
```

```text
    spcname    |       ubicacion        | propietario
---------------+------------------------+-------------
 pg_default    |                        | postgres
 pg_global     |                        | postgres
 tbs_erp       | /tablespaces/erp       | erp_owner
 tbs_empleados | /tablespaces/empleados | emp_owner
(4 rows)
```

`pg_default` y `pg_global` viven dentro del directorio de datos, por eso su ubicación aparece vacía.

![Ubicación de los tablespaces](img/img13.png)

### 5.4 Qué objetos hay en cada espacio

```bash
docker exec empresa-db psql -U postgres -d empresa -c "SELECT schemaname, tablename, tablespace FROM pg_tables WHERE schemaname IN ('erp','empleados');"
docker exec empresa-db psql -U postgres -d empresa -c "SELECT schemaname, indexname, tablespace FROM pg_indexes WHERE schemaname IN ('erp','empleados');"
```

```text
 schemaname | tablename |  tablespace
------------+-----------+---------------
 empleados  | empleados | tbs_empleados
 erp        | clientes  | tbs_erp
 erp        | pedidos   | tbs_erp

 schemaname |   indexname    |  tablespace
------------+----------------+---------------
 erp        | clientes_pkey  | tbs_erp
 erp        | pedidos_pkey   | tbs_erp
 empleados  | empleados_pkey | tbs_empleados
```

![Tablas e índices por tablespace](img/img14.png)

### 5.5 Del catálogo al fichero físico

```bash
docker exec empresa-db psql -U postgres -d empresa -c "SELECT pg_relation_filepath('erp.clientes') AS erp, pg_relation_filepath('empleados.empleados') AS empleados;"
docker exec empresa-db sh -c 'ls -R /tablespaces/erp | head -10'
docker exec empresa-db sh -c 'ls -R /tablespaces/empleados | head -10'
docker inspect empresa-db -f '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'
```

```text
                     erp                     |                  empleados
---------------------------------------------+---------------------------------------------
 pg_tblspc/16386/PG_16_202307071/16388/16392 | pg_tblspc/16387/PG_16_202307071/16388/16413

/tablespaces/erp:
PG_16_202307071

/tablespaces/erp/PG_16_202307071:
16388

/tablespaces/erp/PG_16_202307071/16388:
16392
16396
16397

/tablespaces/empleados:
PG_16_202307071

/tablespaces/empleados/PG_16_202307071:
16388

/tablespaces/empleados/PG_16_202307071/16388:
16413
16417
16418

 -> /etc/postgresql
asgbd-p1_vol_empleados -> /tablespaces/empleados
asgbd-p1_vol_erp -> /tablespaces/erp
asgbd-p1_vol_logs -> /var/log/postgresql
asgbd-p1_vol_pgdata -> /var/lib/postgresql/data
```

**Cómo leerlo:**

| Elemento | Significado |
|---|---|
| `16386` / `16387` | OID del tablespace (`pg_tblspc/` es un enlace simbólico hacia `/tablespaces/...`) |
| `PG_16_202307071` | Directorio que PostgreSQL crea para la versión 16 |
| `16388` | OID de la base de datos `empresa` |
| `16392` / `16413` | Fichero de la tabla `clientes` / `empleados` |
| Montaje sin nombre (`/etc/postgresql`) | *Bind mount* de `./conf`, no es un volumen |

Cada tablespace está en un volumen distinto, lo que cumple el requisito.

![Fichero físico y volúmenes](img/img15.png)

### 5.6 Persistencia tras reiniciar el contenedor

```bash
docker exec empresa-db psql -U postgres -d empresa -c "SELECT (SELECT count(*) FROM erp.clientes) AS erp, (SELECT count(*) FROM empleados.empleados) AS empleados;"
docker restart empresa-db
docker exec empresa-db psql -U postgres -d empresa -c "SELECT (SELECT count(*) FROM erp.clientes) AS erp, (SELECT count(*) FROM empleados.empleados) AS empleados;"
```

```text
 erp | empleados
-----+-----------
   2 |         3

empresa-db

 erp | empleados
-----+-----------
   2 |         3
```

![Datos de los dos espacios tras el reinicio](img/img16.png)

---

## 6. Trazabilidad

**Necesidad:** si alguien intenta conectarse sin permiso debe quedar constancia, aunque el contenedor se destruya.

### 6.1 Configuración

En `postgresql.conf`:

```conf
logging_collector = on
log_directory = '/var/log/postgresql'
log_filename = 'postgresql-%Y-%m-%d.log'
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %q%u@%d (%h) '
```

| Parámetro | Motivo |
|---|---|
| `logging_collector = on` | Escribe los registros en fichero en lugar de en `docker logs` |
| `log_directory` | Apunta al volumen persistente `vol_logs` |
| `log_filename` | Un fichero por día |
| `log_connections` / `log_disconnections` | Registra cada intento de conexión y su fin |
| `log_line_prefix` | Incluye fecha, PID, usuario, base de datos y **IP de origen** (`%h`) |

Al activar el colector, `docker logs` deja de mostrar la actividad del servidor (solo un aviso de redirección). Es lo esperado.

### 6.2 Los rechazos aparecen en el fichero

```bash
docker exec empresa-db sh -c 'grep -h "rejects" /var/log/postgresql/*.log'
```

```text
2026-10-19 08:44:19.029 GMT [851] root@root (172.31.0.3) FATAL:  pg_hba.conf rejects connection for host "172.31.0.3", user "root", database "root", no encryption
2026-10-19 08:44:25.888 GMT [877] analista1@empresa (172.31.0.3) FATAL:  pg_hba.conf rejects connection for host "172.31.0.3", user "analista1", database "empresa", no encryption
```

La primera línea corresponde al `pg_isready` del apartado 2 (que se conecta sin usuario explícito). Queda registrado incluso un simple sondeo.

### 6.3 El registro sobrevive a la destrucción del contenedor

```bash
docker compose down
docker compose up -d --wait
docker exec empresa-db sh -c 'grep -h "rejects" /var/log/postgresql/*.log'
```

Tras destruir y recrear el contenedor, **las mismas dos líneas siguen apareciendo**, porque el fichero vive en el volumen `vol_logs`.

![Rechazos en el log antes y después de destruir el contenedor](img/img17.png)

---

## 7. Cuenta de la aplicación

**Necesidad:** el ERP accede solo a sus datos, un error o ataque en la aplicación no puede modificar la estructura, y la aplicación no puede quedarse sin acceso de forma inesperada.

### 7.1 Diseño

| Elemento | Configuración | Motivo |
|---|---|---|
| `erp_owner` | `NOLOGIN`, propietario del esquema `erp` y sus tablas | Nadie se conecta con él |
| `erp_rw` | Rol de grupo con `SELECT, INSERT, UPDATE, DELETE` y uso de secuencias | Mínimo privilegio: sin `CREATE`, sin `DROP` |
| `erp_app` | `LOGIN`, miembro de `erp_rw`, `CONNECTION LIMIT 45`, `VALID UNTIL 'infinity'` | Cuenta de conexión distinta del propietario |
| `ALTER DEFAULT PRIVILEGES` | Sobre `erp_owner` en el esquema `erp` | Las tablas futuras heredan los privilegios |

Fragmento de `sql/02-roles-privilegios.sql`:

```sql
CREATE ROLE erp_rw NOLOGIN;
GRANT CONNECT ON DATABASE empresa TO erp_rw;

GRANT USAGE ON SCHEMA erp TO erp_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA erp TO erp_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA erp TO erp_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_owner IN SCHEMA erp
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO erp_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_owner IN SCHEMA erp
  GRANT USAGE, SELECT ON SEQUENCES TO erp_rw;

CREATE ROLE erp_app LOGIN PASSWORD :'erp_pwd'
  CONNECTION LIMIT 45 VALID UNTIL 'infinity' IN ROLE erp_rw;
```

**Por qué 45:** 3 instancias × 15 conexiones. Un límite exacto impide que un fallo del ERP consuma las conexiones que necesita el personal.

### 7.2 Lo que SÍ puede hacer

```bash
ERP="docker run --rm --network p1_interna -e PGPASSWORD=$ERP_APP_PASSWORD postgres:16.4 psql -h db -U erp_app -d empresa"
$ERP -c "SELECT current_user;"
$ERP -c "INSERT INTO erp.clientes(nombre) VALUES ('Nuevo cliente');"
$ERP -c "SELECT * FROM erp.clientes;"
$ERP -c "UPDATE erp.clientes SET nombre='Nuevo cliente SL' WHERE nombre='Nuevo cliente';"
```

```text
 current_user
--------------
 erp_app

INSERT 0 1

 id |    nombre
----+---------------
  1 | ACME
  2 | Globex
  3 | Nuevo cliente

UPDATE 1
```

### 7.3 Lo que NO puede hacer

```bash
$ERP -c "CREATE TABLE erp.prueba(x int);"
$ERP -c "DROP TABLE erp.pedidos;"
$ERP -c "ALTER TABLE erp.clientes ADD COLUMN x int;"
$ERP -c "SELECT * FROM empleados.empleados;"
```

```text
ERROR:  permission denied for schema erp
ERROR:  must be owner of table pedidos
ERROR:  must be owner of table clientes
ERROR:  permission denied for schema empleados
```

| Intento | Error | Razón |
|---|---|---|
| `CREATE TABLE` | `permission denied for schema erp` | `erp_rw` no tiene `CREATE` sobre el esquema |
| `DROP TABLE` | `must be owner of table` | Solo el propietario puede borrar, y `erp_app` no lo es |
| `ALTER TABLE` | `must be owner of table` | Ídem |
| Leer empleados | `permission denied for schema empleados` | El ERP solo accede a sus datos |

![Operaciones permitidas y denegadas al ERP](img/img18.png)

### 7.4 Atributos de las cuentas

```bash
docker exec empresa-db psql -U postgres -c "SELECT rolname, rolcanlogin, rolconnlimit, rolvaliduntil FROM pg_roles WHERE rolname IN ('erp_owner','emp_owner','erp_app');"
docker exec empresa-db psql -U postgres -c "SELECT r.rolname AS rol, m.rolname AS miembro_de FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.member JOIN pg_roles m ON m.oid=a.roleid WHERE r.rolname='erp_app';"
```

```text
  rolname  | rolcanlogin | rolconnlimit | rolvaliduntil
-----------+-------------+--------------+---------------
 erp_owner | f           |           -1 |
 emp_owner | f           |           -1 |
 erp_app   | t           |           45 | infinity

   rol   | miembro_de
---------+------------
 erp_app | erp_rw
```

![Atributos de las cuentas del ERP](img/img19.png)

### 7.5 Superar el límite de la cuenta

```bash
docker run --rm --network p1_interna -e PGPASSWORD="$ERP_APP_PASSWORD" \
  postgres:16.4 bash -c '
for i in $(seq 1 50); do
  psql -h db -U erp_app -d empresa -c "select pg_sleep(20)" >/dev/null 2>>/tmp/err &
done
sleep 8
echo "--- Errores recibidos:"
sort /tmp/err | uniq -c
wait'
```

```text
--- Errores recibidos:
      5 psql: error: connection to server at "db" (172.30.0.2), port 5432 failed: FATAL:  too many connections for role "erp_app"
```

De 50 intentos, 45 entran y **5 son rechazados**, justo el exceso sobre el límite. El mensaje (`for role "erp_app"`) es distinto al del apartado 4 porque aquí actúa el límite **de la cuenta**, que se alcanza antes que el global.

![Límite de conexiones del ERP](img/img20.png)

Después se limpia el dato de prueba:

```bash
docker exec empresa-db psql -U postgres -d empresa -c "DELETE FROM erp.clientes WHERE nombre LIKE 'Nuevo cliente%';"
```

---

## 8. Acceso del personal

**Necesidad:** cada persona tiene su cuenta, y dar de alta o de baja a un analista no debe obligar a revisar privilegios uno a uno.

### 8.1 Diseño

| Elemento | Configuración |
|---|---|
| `rol_rrhh` | Rol de grupo (`NOLOGIN`): `SELECT, INSERT, UPDATE, DELETE` sobre el esquema `empleados` |
| `rol_analista` | Rol de grupo (`NOLOGIN`): `SELECT` sobre el esquema `erp` y `SELECT (id, nombre, departamento)` sobre `empleados.empleados` |
| `rrhh1`, `rrhh2` | Cuentas personales, miembros de `rol_rrhh` |
| `analista1`, `analista2`, `analista3` | Cuentas personales, miembros de `rol_analista` |
| Caducidad | `VALID UNTIL` a 90 días desde el alta |
| Privilegio por columna | La columna `salario` no se concede al rol de analistas |

```sql
GRANT USAGE ON SCHEMA erp, empleados TO rol_analista;
GRANT SELECT ON ALL TABLES IN SCHEMA erp TO rol_analista;
GRANT SELECT (id, nombre, departamento) ON empleados.empleados TO rol_analista;

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L VALID UNTIL %L IN ROLE rol_analista',
              u, :'user_pwd', CURRENT_DATE + 90)
FROM unnest(ARRAY['analista1','analista2','analista3']) AS u \gexec
```

**Sobre la caducidad:** PostgreSQL **no obliga** a cambiar la contraseña. `VALID UNTIL` solo impide iniciar sesión pasada esa fecha. La renovación se hace con `ALTER ROLE persona VALID UNTIL 'fecha';`.

### 8.2 Un analista: consulta empleados pero no el salario

```bash
AN="docker run --rm --network p1_interna -e PGPASSWORD=$INITIAL_USER_PASSWORD postgres:16.4 psql -h db -d empresa"
$AN -U analista1 -c "SELECT id, nombre, departamento FROM empleados.empleados;"
$AN -U analista1 -c "SELECT salario FROM empleados.empleados;"
$AN -U analista1 -c "SELECT * FROM empleados.empleados;"
$AN -U analista1 -c "SELECT * FROM erp.pedidos;"
$AN -U analista1 -c "UPDATE empleados.empleados SET departamento='X' WHERE id=1;"
```

```text
 id | nombre | departamento
----+--------+--------------
  1 | Ana    | RRHH
  2 | Luis   | IT
  3 | Marta  | Ventas

ERROR:  permission denied for table empleados
ERROR:  permission denied for table empleados

 id | cliente_id | importe
----+------------+---------
  1 |          1 |  100.50
  2 |          2 |  250.00

ERROR:  permission denied for table empleados
```

`SELECT *` también falla porque incluye la columna `salario`: PostgreSQL exige privilegio sobre **todas** las columnas referenciadas. Los analistas deben nombrar las columnas.

![Analista: consulta permitida y salario rechazado](img/img21.png)

### 8.3 Personal de RRHH

```bash
$AN -U rrhh1 -c "SELECT * FROM empleados.empleados;"
$AN -U rrhh1 -c "UPDATE empleados.empleados SET salario=2600 WHERE id=1;"
$AN -U rrhh1 -c "SELECT * FROM erp.pedidos;"
$AN -U rrhh1 -c "UPDATE empleados.empleados SET salario=2500 WHERE id=1;"
```

```text
 id | nombre | departamento | salario
----+--------+--------------+---------
  1 | Ana    | RRHH         | 2500.00
  2 | Luis   | IT           | 3100.00
  3 | Marta  | Ventas       | 2800.00

UPDATE 1
ERROR:  permission denied for schema erp
UPDATE 1
```

RRHH ve y modifica salarios, pero no tiene acceso al ERP. La última sentencia restaura el valor original.

![Operaciones del personal de RRHH](img/img22.png)

### 8.4 Alta de un analista nuevo: solo asignar el rol

```bash
docker exec empresa-db psql -U postgres -c "CREATE ROLE analista4 LOGIN PASSWORD '$INITIAL_USER_PASSWORD' VALID UNTIL '$(date -d '+90 days' +%F)';"
docker exec empresa-db psql -U postgres -c "GRANT rol_analista TO analista4;"
$AN -U analista4 -c "SELECT count(*) FROM erp.pedidos;"
$AN -U analista4 -c "SELECT id, nombre FROM empleados.empleados;"
$AN -U analista4 -c "SELECT salario FROM empleados.empleados;"
```

```text
CREATE ROLE
GRANT ROLE

 count
-------
     2

 id | nombre
----+--------
  2 | Luis
  3 | Marta
  1 | Ana

ERROR:  permission denied for table empleados
```

Con un único `GRANT rol_analista` la persona nueva puede hacer las mismas consultas que el resto, **sin ningún privilegio individual**, y el salario le es rechazado igual.

### 8.5 Baja: retirar el rol

```bash
docker exec empresa-db psql -U postgres -c "REVOKE rol_analista FROM analista4;"
$AN -U analista4 -c "SELECT count(*) FROM erp.pedidos;"
```

```text
REVOKE ROLE

psql: error: connection to server at "db" (172.30.0.2), port 5432 failed: FATAL:  permission denied for database "empresa"
DETAIL:  User does not have CONNECT privilege.
```

Al retirar el rol, la persona pierde **todos** los privilegios, incluso el de conectarse. Esto se debe a que se hizo `REVOKE ALL ON DATABASE empresa FROM PUBLIC` y el `CONNECT` se concedió únicamente a los roles de grupo. Es un comportamiento deseable en una baja.

![Alta y baja de un analista](img/img23.png)

Limpieza:

```bash
docker exec empresa-db psql -U postgres -c "DROP ROLE analista4;"
```

### 8.6 Evidencia desde el diccionario de datos

```bash
docker exec empresa-db psql -U postgres -c "SELECT r.rolname AS persona, m.rolname AS rol, r.rolvaliduntil FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.member JOIN pg_roles m ON m.oid=a.roleid WHERE r.rolname NOT LIKE 'pg_%' AND r.rolname <> 'erp_app' ORDER BY 2,1;"
docker exec empresa-db psql -U postgres -d empresa -c "SELECT grantee, table_name, column_name, privilege_type FROM information_schema.column_privileges WHERE grantee='rol_analista' AND table_schema='empleados' ORDER BY column_name;"
```

```text
  persona   |         rol          |     rolvaliduntil
------------+----------------------+------------------------
 analista1  | rol_analista         | 2027-01-17 00:00:00+00
 analista2  | rol_analista         | 2027-01-17 00:00:00+00
 analista3  | rol_analista         | 2027-01-17 00:00:00+00
 rrhh1      | rol_rrhh             | 2027-01-17 00:00:00+00
 rrhh2      | rol_rrhh             | 2027-01-17 00:00:00+00

   grantee    | table_name | column_name  | privilege_type
--------------+------------+--------------+----------------
 rol_analista | empleados  | departamento | SELECT
 rol_analista | empleados  | id           | SELECT
 rol_analista | empleados  | nombre       | SELECT
```

La segunda consulta demuestra, desde el diccionario de datos, que `rol_analista` tiene `SELECT` sobre `id`, `nombre` y `departamento`, y **no** sobre `salario`.

![Roles, caducidad y privilegios por columna](img/img24.png)

---

## 9. Ampliación: caída súbita (opcional)

> **Pendiente de realizar.** Esta sección se completará tras ejecutar las pruebas.

Configuración ya aplicada: `restart: unless-stopped` en el `docker-compose.yml`.

```bash
docker inspect empresa-db -f '{{.HostConfig.RestartPolicy.Name}}'
```

Por documentar:

- [ ] Caso A: transacción con `COMMIT` conservada y transacción sin confirmar descartada tras `docker kill -s KILL`
- [ ] Caso B: pérdida de una transacción confirmada con `synchronous_commit = off`

---

## 10. Problemas encontrados y cómo se resolvieron

| Problema | Causa | Solución |
|---|---|---|
| `Docker API ... dockerDesktopLinuxEngine not found` | Docker Desktop no estaba arrancado | Abrir Docker Desktop y esperar a *Engine running* |
| `Pool overlaps with other one on this address space` | Redes de otra asignatura (`p1_internal_net`, `p1_visitor_net`) ya ocupaban `172.30.0.0/24` y `172.31.0.0/24` | Comprobar que no tenían contenedores conectados y eliminarlas con `docker network rm` |
| Aviso de contenedores huérfanos (`erp_postgres`) | Otro proyecto también usaba el nombre `p1` | Renombrar el proyecto a `asgbd-p1`. **No** usar `--remove-orphans`, que borraría un contenedor ajeno |
| `container name "/empresa-db" is already in use` | Cambié `name:` del compose sin hacer antes `docker compose down -v` | Eliminar el contenedor, redes y volúmenes antiguos, y volver a montar |
| `volume is in use` al borrar volúmenes | Un contenedor parado seguía referenciándolos | Localizarlo con `docker ps -a --filter volume=...` y eliminarlo |
| `ls: cannot access 'C:/Program Files/Git/var/log/...'` | Git Bash convierte las rutas que empiezan por `/` | Usar `sh -c '...'` o `MSYS_NO_PATHCONV=1` |
| `bash: .env: No such file or directory` | Ejecuté `source .env` desde la raíz y no desde `p1/` | Ejecutarlo siempre desde `p1/` |
| 9 rechazos en vez de los 8 previstos | No verificado (véase apartado 4.3) | Contar sesiones con `pg_stat_activity` durante la prueba |

**Lección aprendida:** el nombre del proyecto de Compose se usa como prefijo de los volúmenes y como etiqueta de pertenencia de las redes. Cambiarlo con recursos ya creados los deja huérfanos, por lo que hay que hacer `docker compose down -v` **antes** de renombrar.

---

## 11. Preguntas previsibles para la defensa oral

| Pregunta | Dónde está la respuesta |
|---|---|
| ¿Cambia un parámetro en directo? | `ALTER SYSTEM SET work_mem` + `pg_reload_conf()` (apartado 3.5), o a nivel de sesión con `SET work_mem` |
| ¿Por qué `work_mem` y no `shared_buffers` se cambia sin reiniciar? | Columna `context` de `pg_settings`: `user` frente a `postmaster` |
| ¿Cómo se da de alta a un analista? | `CREATE ROLE ... LOGIN ... VALID UNTIL ...` y `GRANT rol_analista TO ...` (apartado 8.4) |
| ¿Cómo se da de baja? | `REVOKE rol_analista FROM ...` (apartado 8.5) |
| ¿Por qué 55 conexiones? | Apartado 4.1 |
| ¿Quién rechaza a los visitantes? | El SGBD, mediante `pg_hba.conf` (apartado 2) |
| ¿Por qué el ERP no puede borrar tablas? | No es propietario y no tiene `CREATE` (apartado 7.3) |
| ¿Cómo se protege el salario? | Privilegio por columna (apartado 8.1) |
