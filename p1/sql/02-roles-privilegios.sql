\connect empresa

-- Roles de grupo (sin login): un rol por perfil de trabajo
CREATE ROLE erp_rw       NOLOGIN;
CREATE ROLE rol_rrhh     NOLOGIN;
CREATE ROLE rol_analista NOLOGIN;

GRANT CONNECT ON DATABASE empresa TO erp_rw, rol_rrhh, rol_analista;

-- ERP: solo DML sobre su esquema (sin CREATE, sin DROP)
GRANT USAGE ON SCHEMA erp TO erp_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA erp TO erp_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA erp TO erp_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_owner IN SCHEMA erp
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO erp_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_owner IN SCHEMA erp
  GRANT USAGE, SELECT ON SEQUENCES TO erp_rw;

-- RRHH: consultar y modificar empleados
GRANT USAGE ON SCHEMA empleados TO rol_rrhh;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA empleados TO rol_rrhh;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA empleados TO rol_rrhh;

-- Analistas: ERP (lectura) y empleados SIN la columna salario
GRANT USAGE ON SCHEMA erp, empleados TO rol_analista;
GRANT SELECT ON ALL TABLES IN SCHEMA erp TO rol_analista;
ALTER DEFAULT PRIVILEGES FOR ROLE erp_owner IN SCHEMA erp
  GRANT SELECT ON TABLES TO rol_analista;
GRANT SELECT (id, nombre, departamento) ON empleados.empleados TO rol_analista;

-- Cuenta de conexión del ERP: máx. 45 conexiones, contraseña sin caducidad
CREATE ROLE erp_app LOGIN PASSWORD :'erp_pwd'
  CONNECTION LIMIT 45 VALID UNTIL 'infinity' IN ROLE erp_rw;

-- Personas: cuenta propia, caduca a 90 días, privilegios solo vía rol
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L VALID UNTIL %L IN ROLE rol_rrhh',
              u, :'user_pwd', CURRENT_DATE + 90)
FROM unnest(ARRAY['rrhh1','rrhh2']) AS u \gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L VALID UNTIL %L IN ROLE rol_analista',
              u, :'user_pwd', CURRENT_DATE + 90)
FROM unnest(ARRAY['analista1','analista2','analista3']) AS u \gexec
